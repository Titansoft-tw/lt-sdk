package com.tswork.lt.telemetry

/**
 * What the remote telemetry config (`<collector base>/config/telemetry.json`, schema 1; lt-call-demo
 * docs/telemetry-delivery-proposal.md §4.3) lets the server change without an app release. Every value is clamped to a
 * safe range, so no file, however wrong, can break the app or flood the collector. [version] is null while only the
 * built-in defaults apply; otherwise records carry it as `config_version`.
 */
data class TelemetrySettings(
    val enabled: Boolean = true,
    /** Send one quality_second every N seconds (the on-screen diagnostics stay per second). Next call. */
    val qualityEverySec: Int = 1,
    /** Share of calls that send quality_second at all; events and errors are always sent. Next call. */
    val callSamplePercent: Int = 100,
    /** quality_second records batched per send (lt-call-demo's outbox). Next call. */
    val batchRecords: Int = 3,
    val retryBaseMs: Long = LtTelemetry.RETRY_MS,
    val retryMaxMs: Long = LtTelemetry.MAX_RETRY_MS,
    /** Disk queue limits; take effect at the next launch. */
    val queueMaxBytes: Long = TelemetryStore.DEFAULT_MAX_BYTES,
    val queueMaxAgeMs: Long = TelemetryStore.DEFAULT_MAX_AGE_MS,
    /** sdk_event labels not to send; never affects app_error or abnormal_exit. */
    val dropLabels: Set<String> = emptySet(),
    val version: Int? = null,
)

/** What the rules match on: `android` / `ios`, the app's version name, `debug` / `release`. */
data class ConfigTarget(val platform: String, val appVersion: String, val build: String)

object RemoteTelemetryConfig {
    const val SCHEMA = 1
    const val MAX_DROP_LABELS = 50

    /**
     * The settings [json] gives [target], or null when the file is unusable (not JSON, not an object, schema ≠ 1,
     * no integer version): the caller then keeps its last good settings. [bucket] (0–99) is this install's local
     * rollout bucket; a rule with `rollout_percent` applies only when bucket < percent. Unknown fields are ignored.
     */
    fun parse(json: String, target: ConfigTarget, bucket: Int): TelemetrySettings? {
        val root = runCatching { MiniJson.parse(json) }.getOrNull() as? Map<*, *> ?: return null
        if ((root["schema"] as? Double)?.toInt() != SCHEMA) return null
        val version = (root["version"] as? Double)?.takeIf { it >= 0 && it == Math.floor(it) && it <= Int.MAX_VALUE }?.toInt() ?: return null
        val merged = LinkedHashMap<Any?, Any?>()
        (root["telemetry"] as? Map<*, *>)?.let(merged::putAll)
        for (rule in root["rules"] as? List<*> ?: emptyList<Any?>()) {
            val r = rule as? Map<*, *> ?: continue
            if (!matches(r["match"] as? Map<*, *>, target)) continue
            val percent = (r["rollout_percent"] as? Double)?.coerceIn(0.0, 100.0) ?: 100.0
            if (bucket >= percent) continue
            (r["telemetry"] as? Map<*, *>)?.let(merged::putAll)
        }
        return settings(merged, version)
    }

    private fun settings(m: Map<*, *>, version: Int): TelemetrySettings {
        val d = TelemetrySettings()
        fun int(key: String, default: Long, min: Long, max: Long): Long =
            (m[key] as? Double)?.takeIf { it.isFinite() }?.toLong()?.coerceIn(min, max) ?: default
        val retryBaseS = int("retry_base_s", d.retryBaseMs / 1000, 5, 300)
        return TelemetrySettings(
            enabled = m["enabled"] as? Boolean ?: d.enabled,
            qualityEverySec = int("quality_every_s", d.qualityEverySec.toLong(), 1, 10).toInt(),
            callSamplePercent = int("call_sample_percent", d.callSamplePercent.toLong(), 0, 100).toInt(),
            batchRecords = int("batch_records", d.batchRecords.toLong(), 1, 30).toInt(),
            retryBaseMs = retryBaseS * 1000,
            retryMaxMs = int("retry_max_s", d.retryMaxMs / 1000, retryBaseS, 3600) * 1000,
            queueMaxBytes = int("queue_max_kb", d.queueMaxBytes / 1024, 512, 20_480) * 1024,
            queueMaxAgeMs = int("queue_max_age_h", d.queueMaxAgeMs / 3_600_000, 1, 720) * 3_600_000,
            dropLabels = (m["drop_labels"] as? List<*>).orEmpty().filterIsInstance<String>().filter { it.isNotBlank() }
                .take(MAX_DROP_LABELS).toSet(),
            version = version,
        )
    }

    private fun matches(match: Map<*, *>?, target: ConfigTarget): Boolean {
        match ?: return true
        (match["platform"] as? String)?.let { if (!it.equals(target.platform, ignoreCase = true)) return false }
        (match["build"] as? String)?.let { if (!it.equals(target.build, ignoreCase = true)) return false }
        (match["app_version_min"] as? String)?.let { if (compareVersions(target.appVersion, it) < 0) return false }
        (match["app_version_below"] as? String)?.let { if (compareVersions(target.appVersion, it) >= 0) return false }
        return true
    }

    /** Numeric, segment by segment ("1.10.0" > "1.9"); a segment's leading digits count, the rest ("0-debug") is ignored. */
    fun compareVersions(a: String, b: String): Int {
        fun parts(v: String) = v.trim().split('.').map { s -> s.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        val x = parts(a); val y = parts(b)
        for (i in 0 until maxOf(x.size, y.size)) {
            val c = (x.getOrElse(i) { 0 }).compareTo(y.getOrElse(i) { 0 })
            if (c != 0) return c
        }
        return 0
    }
}

/**
 * The small JSON reader the config needs (lt-sdk has no dependencies, and android.jar's org.json is a stub in unit
 * tests): objects → Map, arrays → List, numbers → Double, plus String, Boolean and null. Throws on malformed input.
 */
internal object MiniJson {
    fun parse(text: String): Any? = Reader(text).run { val v = value(); space(); require(i == s.length) { "trailing data" }; v }

    private class Reader(val s: String) {
        var i = 0
        fun space() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun value(): Any? {
            space()
            require(i < s.length) { "end of input" }
            return when (val c = s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> if (c == '-' || c.isDigit()) num() else throw IllegalArgumentException("unexpected '$c'")
            }
        }
        fun word(w: String, v: Any?): Any? { require(s.startsWith(w, i)) { "bad literal" }; i += w.length; return v }
        fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++; space()
            if (s.getOrNull(i) == '}') { i++; return m }
            while (true) {
                space(); require(s.getOrNull(i) == '"') { "key expected" }
                val k = str(); space(); require(s.getOrNull(i) == ':') { "':' expected" }; i++
                m[k] = value(); space()
                when (s.getOrNull(i)) { ',' -> i++; '}' -> { i++; return m }; else -> throw IllegalArgumentException("',' or '}' expected") }
            }
        }
        fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            i++; space()
            if (s.getOrNull(i) == ']') { i++; return l }
            while (true) {
                l += value(); space()
                when (s.getOrNull(i)) { ',' -> i++; ']' -> { i++; return l }; else -> throw IllegalArgumentException("',' or ']' expected") }
            }
        }
        fun str(): String {
            val b = StringBuilder()
            i++
            while (true) {
                require(i < s.length) { "unterminated string" }
                when (val c = s[i++]) {
                    '"' -> return b.toString()
                    '\\' -> {
                        require(i < s.length) { "bad escape" }
                        when (val e = s[i++]) {
                            '"', '\\', '/' -> b.append(e)
                            'b' -> b.append('\b'); 'f' -> b.append('\u000c'); 'n' -> b.append('\n'); 'r' -> b.append('\r'); 't' -> b.append('\t')
                            'u' -> { require(i + 4 <= s.length) { "bad \\u" }; b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                            else -> throw IllegalArgumentException("bad escape")
                        }
                    }
                    else -> b.append(c)
                }
            }
        }
        fun num(): Double {
            val start = i
            if (s[i] == '-') i++
            while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
            return s.substring(start, i).toDouble()
        }
    }
}

/**
 * Which per-second samples one call sends, from the [TelemetrySettings] in effect when it started (fixed for the
 * call, so its data stays consistent). [roll] is a random 0–99 drawn per call for `call_sample_percent`.
 */
class QualitySampling(settings: TelemetrySettings, roll: Int) {
    /** Whether this call sends quality_second at all. */
    val sendsQuality = roll < settings.callSamplePercent
    /** quality_second records to batch before a send. */
    val batch = settings.batchRecords
    private val every = settings.qualityEverySec
    private var seen = 0
    /** Call once per measured sample: true for the first and then every [TelemetrySettings.qualityEverySec]-th. */
    fun take(): Boolean = sendsQuality && seen++ % every == 0
}
