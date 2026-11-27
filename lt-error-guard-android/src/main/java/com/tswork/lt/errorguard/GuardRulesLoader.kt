package com.tswork.lt.errorguard

import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/*
 * Remote rules (lt-error-guard-spec README "Remote rules"): a signed envelope { rulesVersion, rules } at [url] and
 * its ECDSA P-256 / SHA-256 signature (base64 DER) at [signatureUrl]. Only a correctly signed, valid and newer file
 * replaces the guard's rules; anything else keeps the current ones. iOS: LtErrorGuard/GuardRulesLoader.swift.
 */

/** What one [GuardRulesLoader.refresh] did. */
sealed interface RulesUpdate {
    /** The guard now uses rules [version]. */
    data class Applied(val version: Int) : RulesUpdate
    /** The file is not newer than the rules in use ([version]). */
    data class Unchanged(val version: Int) : RulesUpdate
    /** Downloaded but refused; [reason] starts with `signature`, `envelope` or `rules`. */
    data class Rejected(val reason: String) : RulesUpdate
    /** Not downloaded (network, HTTP status, size). */
    data class Failed(val reason: String) : RulesUpdate
}

/**
 * ```kotlin
 * val loader = GuardRulesLoader(guard, "https://cdn.example.com/guard/android.json", BuildConfig.GUARD_RULES_PUBLIC_KEY,
 *     cacheFile = File(context.noBackupFilesDir, "guard-rules.json"), onApplied = { Sentry.setTag("guard_rules_version", "$it") })
 * loader.applyCached()                       // at start, before Sentry sends anything
 * val periodic = loader.startPeriodic()      // refresh now and every 6 h on a daemon thread
 * ```
 */
class GuardRulesLoader @JvmOverloads constructor(
    private val guard: ErrorGuard,
    private val url: String,
    /** PEM (`-----BEGIN PUBLIC KEY-----`) or base64 of the SPKI DER; an invalid key throws IllegalArgumentException. */
    publicKey: String,
    /** Where the last applied file and its signature (`<name>.sig`) are kept; null = no cache. */
    private val cacheFile: File?,
    private val signatureUrl: String = "$url.sig",
    /** GET returning the body; throws on failure. The default needs https and caps the body at [MAX_BYTES]. */
    private val fetch: (String) -> ByteArray = ::httpGet,
    /** Called with the new version after rules are applied (e.g. to tag crash reports). */
    private val onApplied: (Int) -> Unit = {},
    /** One line per outcome that changes something or fails; never the URL. */
    private val log: (String) -> Unit = {},
) {
    private val key: PublicKey = parsePublicKey(publicKey)
    private val sigFile = cacheFile?.let { File(it.path + ".sig") }

    /** The rules version in use: 0 = the app's own rules (nothing remote applied yet). */
    @Volatile var version: Int = 0
        private set

    /** Applies the cached file when it is still correctly signed and valid. Returns whether it did. */
    @Synchronized fun applyCached(): Boolean {
        val file = cacheFile ?: return false
        val sig = sigFile ?: return false
        if (!file.exists() || !sig.exists()) return false
        val outcome = runCatching { apply(file.readBytes(), sig.readBytes(), cache = false) }.getOrElse { RulesUpdate.Rejected("envelope: ${it.message}") }
        if (outcome !is RulesUpdate.Applied) log("guard rules: cached file ignored ($outcome)")
        return outcome is RulesUpdate.Applied
    }

    /** Downloads, checks and applies the remote file. Blocking: call it off the main thread. */
    @Synchronized fun refresh(): RulesUpdate {
        val body: ByteArray
        val signature: ByteArray
        try {
            body = fetch(url)
            signature = fetch(signatureUrl)
        } catch (e: Exception) {
            return RulesUpdate.Failed(e.message ?: e.javaClass.simpleName).also { log("guard rules: download failed (${it.reason})") }
        }
        return apply(body, signature, cache = true).also { if (it !is RulesUpdate.Unchanged) log("guard rules: $it") }
    }

    /** [refresh] now and then every [intervalMs] on one daemon thread; close the result to stop. */
    @JvmOverloads fun startPeriodic(intervalMs: Long = TimeUnit.HOURS.toMillis(6)): AutoCloseable {
        val executor = Executors.newSingleThreadScheduledExecutor { Thread(it, "lt-error-guard-rules").apply { isDaemon = true } }
        executor.scheduleWithFixedDelay({ runCatching { refresh() } }, 0, intervalMs, TimeUnit.MILLISECONDS)
        return AutoCloseable { executor.shutdownNow() }
    }

    private fun apply(body: ByteArray, signature: ByteArray, cache: Boolean): RulesUpdate {
        if (!verify(key, body, signature)) return RulesUpdate.Rejected("signature: does not match the public key")
        val (next, rules) = try { parseEnvelope(body) } catch (e: IllegalArgumentException) { return RulesUpdate.Rejected(e.message.orEmpty()) }
        if (next <= version) return RulesUpdate.Unchanged(version)
        guard.updateRules(rules)
        version = next
        val file = cacheFile
        val sig = sigFile
        if (cache && file != null && sig != null) {
            runCatching { write(file, body); write(sig, signature) }.onFailure { log("guard rules: cache not written (${it.message})") }
        }
        runCatching { onApplied(next) }
        return RulesUpdate.Applied(next)
    }

    companion object {
        /** Largest rules file the default fetch accepts. */
        const val MAX_BYTES = 256 * 1024

        /** The version and rules in an envelope; IllegalArgumentException starting with `envelope` or `rules` otherwise. */
        @JvmStatic fun parseEnvelope(body: ByteArray): Pair<Int, GuardRules> {
            val root = runCatching { JSONTokener(String(body, Charsets.UTF_8)).nextValue() }.getOrNull() as? JSONObject
                ?: throw IllegalArgumentException("envelope: must be a JSON object")
            val problems = mutableListOf<String>()
            for (k in root.keys()) if (k != "rulesVersion" && k != "rules") problems += "envelope: unknown key $k"
            val version = (root.opt("rulesVersion") as? Number)?.toDouble()?.takeIf { it % 1.0 == 0.0 && it in 1.0..1e9 }?.toInt()
            if (version == null) problems += "envelope: rulesVersion must be an integer from 1 to 1000000000"
            val rules = root.opt("rules") as? JSONObject
            if (rules == null) problems += "envelope: rules must be an object"
            require(problems.isEmpty()) { problems.joinToString("\n") }
            val parsed = try { GuardRules.parse(rules.toString()) } catch (e: IllegalArgumentException) {
                throw IllegalArgumentException(e.message.orEmpty().lines().joinToString("\n") { "rules.$it" })
            }
            return version!! to parsed
        }

        /** ECDSA P-256 / SHA-256 over [body]; [signature] is base64 DER (surrounding whitespace allowed). */
        @JvmStatic fun verify(key: PublicKey, body: ByteArray, signature: ByteArray): Boolean = runCatching {
            val der = Base64.getDecoder().decode(String(signature, Charsets.US_ASCII).trim())
            Signature.getInstance("SHA256withECDSA").run { initVerify(key); update(body); verify(der) }
        }.getOrDefault(false)

        @JvmStatic fun parsePublicKey(text: String): PublicKey = try {
            val b64 = text.lines().filterNot { it.startsWith("-----") }.joinToString("").filterNot(Char::isWhitespace)
            KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(b64)))
        } catch (e: Exception) {
            throw IllegalArgumentException("publicKey: not an EC public key (PEM or base64 SPKI DER)", e)
        }

        private fun write(file: File, bytes: ByteArray) {
            val tmp = File(file.path + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.delete(); if (!tmp.renameTo(file)) throw IOException("rename failed") }
        }

        private fun httpGet(url: String): ByteArray {
            require(url.startsWith("https://")) { "https only" }
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 10_000; c.readTimeout = 10_000; c.useCaches = false
                if (c.responseCode != 200) throw IOException("HTTP ${c.responseCode}")
                val out = ByteArrayOutputStream()
                c.inputStream.use { input ->
                    val buf = ByteArray(8192)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > MAX_BYTES) throw IOException("larger than $MAX_BYTES bytes")
                    }
                }
                return out.toByteArray()
            } finally { c.disconnect() }
        }
    }
}
