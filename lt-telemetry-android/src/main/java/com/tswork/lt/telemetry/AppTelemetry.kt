package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.DeviceState
import com.tswork.lt.deviceinfo.Thermal
import java.io.IOException
import java.io.InterruptedIOException
import java.net.URLDecoder
import java.net.URLEncoder

/*
 * Error log and device state (lt-observability contract: app_error, sdk_event label=env / device_power /
 * mic / abnormal_exit / app_start, and the device fields on quality_second). Pure code; iOS mirrors it in
 * LtTelemetry/AppTelemetry.swift. DeviceState, Thermal and ExitReasons live in lt-device-info.
 */

/** OTLP severityText. Everything that is not an app_error stays INFO. */
object Severity {
    const val INFO = "INFO"
    const val WARN = "WARN"
    const val ERROR = "ERROR"
    const val FATAL = "FATAL"
}

/** `error_domain`: the contract's closed list. */
enum class ErrorDomain(val code: String) {
    APP_EXIT("app_exit"), CRASH("crash"), RTC("rtc"), API("api"), SIGNALING("signaling"),
    AUDIO("audio"), PERMISSION("permission"), TELEMETRY("telemetry"), PUSH("push"),
}

/**
 * One error. [code] must be stable enough to group by (`http_503`, `agora_join_failed_17`), never
 * free text; [detail] is free text and is scrubbed before it leaves the device. [fatal] means the
 * process or the call ended because of it.
 */
data class AppError(
    val domain: ErrorDomain,
    val code: String,
    val detail: String = "",
    val fatal: Boolean = false,
    val severity: String = if (domain == ErrorDomain.APP_EXIT) Severity.FATAL else Severity.ERROR,
    /** The Sentry event behind a crash (32 hex), sent as `sentry_event_id`; blank = unknown, not sent. */
    val sentryEventId: String = "",
)

/** Thrown by relay clients for an HTTP answer that is not a success; the message is the user-facing text. */
class RelayHttpException(val status: Int, message: String) : IllegalStateException(message)

/** A failure that already knows its app_error (e.g. an Agora join refused with a code). */
class AppErrorException(val error: AppError, message: String) : IllegalStateException(message)

/** Relay API failures → `error_code` (domain api). */
object ApiErrors {
    /** -1 = timed out, 0 = no answer (network), anything else the HTTP status. */
    fun status(status: Int) = when (status) { -1 -> "http_timeout"; 0 -> "http_network"; else -> "http_$status" }
    /** Null when [e] is not an API failure (a programming or validation error). */
    fun code(e: Throwable): String? = when (e) {
        is RelayHttpException -> status(e.status)
        is InterruptedIOException -> "http_timeout" // OkHttp's callTimeout and SocketTimeoutException
        is IOException -> "http_network"
        else -> null
    }
    fun error(e: Throwable, what: String): AppError? = code(e)?.let { AppError(ErrorDomain.API, it, what) }
}

/** Signaling WebSocket failures (domain signaling). */
object SignalingErrors {
    /** Close codes that end the call: the relay refused the ticket or the same user joined elsewhere. */
    private val TERMINAL = setOf(4401, 4000)
    /** Null for a normal close. Anything else reconnects on its own (WARN) unless the relay refused us. */
    fun closed(code: Int): AppError? = if (code == 1000) null else AppError(ErrorDomain.SIGNALING, "ws_close_$code",
        fatal = code in TERMINAL, severity = if (code in TERMINAL) Severity.ERROR else Severity.WARN)
    fun connectFailed() = AppError(ErrorDomain.SIGNALING, "ws_connect_failed", severity = Severity.WARN)
}

/** `label=mic` reasons (contract enum). */
enum class MicEvent(val reason: String, val event: String) {
    PERMISSION_DENIED("permission_denied", "microphone permission denied"),
    SILENCED("silenced", "microphone silenced by the system"),
    UNSILENCED("unsilenced", "microphone no longer silenced"),
    FOCUS_LOST("focus_lost", "audio focus lost"),
    FOCUS_GAINED("focus_gained", "audio focus gained"),
    INTERRUPTED_BY_CALL("interrupted_by_call", "audio interrupted by another call"),
    MEDIA_RESET("media_reset", "media services were reset"),
    SILENT_CAPTURE("silent_capture", "microphone captures only silence"),
}

/** One `sdk_event` the controller should send for a device change. */
data class DeviceChange(val label: String, val reason: String, val event: String)

/**
 * Turns the once-a-second [DeviceState] into `device_power` and `mic` events, only on a change,
 * and spots a microphone that sends only silence. One instance per call session.
 */
class DeviceWatch(private val silentSeconds: Int = SILENT_CAPTURE_SECONDS) {
    private var last = DeviceState()
    private var started = false
    private var batteryKnown = false
    private val batteryFired = mutableSetOf<Int>()
    private var silentRun = 0
    private var silentReported = false

    fun observe(context: TelemetryContext): List<DeviceChange> {
        val now = context.device
        val before = last
        // Keep the last known value of each field: a second the platform could not read is not a change.
        last = DeviceState(
            batteryPct = now.batteryPct ?: before.batteryPct, powerSave = now.powerSave ?: before.powerSave,
            thermal = now.thermal ?: before.thermal, doze = now.doze ?: before.doze,
            micSilenced = now.micSilenced ?: before.micSilenced, phoneCall = now.phoneCall ?: before.phoneCall,
        )
        // The call's env snapshot describes the start: thresholds already crossed at the first known reading are not news.
        val firstPct = now.batteryPct
        if (!batteryKnown && firstPct != null) {
            batteryKnown = true
            BATTERY_THRESHOLDS.filter { firstPct < it }.forEach { batteryFired += it }
        }
        if (!started) { started = true; return emptyList() }
        return buildList {
            fun power(reason: String, event: String) = add(DeviceChange("device_power", reason, event))
            fun mic(e: MicEvent) = add(DeviceChange("mic", e.reason, e.event))
            // DeviceState is in another module, so its properties are read into locals (no cross-module smart casts).
            val powerSave = now.powerSave; val thermal = now.thermal; val thermalBefore = before.thermal
            val doze = now.doze; val micSilenced = now.micSilenced
            if (powerSave != null && before.powerSave != null && powerSave != before.powerSave)
                power(if (powerSave) "power_save_on" else "power_save_off", "power save ${if (powerSave) "on" else "off"}")
            if (thermal != null && thermalBefore != null && thermal != thermalBefore)
                power("thermal_${Thermal.name(thermal)}", "thermal ${Thermal.name(thermalBefore)} -> ${Thermal.name(thermal)}")
            now.batteryPct?.let { pct ->
                for (threshold in BATTERY_THRESHOLDS) if (pct < threshold && batteryFired.add(threshold)) power("battery_low_$threshold", "battery below $threshold%")
            }
            if (doze != null && before.doze != null && doze != before.doze)
                power(if (doze) "doze_on" else "doze_off", "doze ${if (doze) "on" else "off"}")
            if (micSilenced != null && before.micSilenced != null && micSilenced != before.micSilenced)
                mic(if (micSilenced) MicEvent.SILENCED else MicEvent.UNSILENCED)
            if (now.phoneCall == true && before.phoneCall == false) mic(MicEvent.INTERRUPTED_BY_CALL)
        }
    }

    /**
     * True once when the microphone volume (Agora `agora_mic_volume`) has been 0 for [silentSeconds]
     * samples in a row while the user has not muted and audio is being sent. Unknown volume never counts.
     */
    fun silentCapture(metrics: AudioMetrics?, muted: Boolean): Boolean {
        val volume = metrics?.extra?.get("agora_mic_volume")?.toIntOrNull()
        val sending = (metrics?.sendKbps ?: 0.0) > 0.0
        if (volume == null || volume > 0 || muted || !sending) {
            silentRun = 0
            if (volume != null && volume > 0) silentReported = false
            return false
        }
        silentRun++
        if (silentRun >= silentSeconds && !silentReported) { silentReported = true; return true }
        return false
    }

    companion object {
        /** D5: conservative, so a user who simply says nothing is not reported. */
        const val SILENT_CAPTURE_SECONDS = 10
        val BATTERY_THRESHOLDS = listOf(20, 10, 5)
    }
}

/** Per call: the first occurrence of a code is sent at once, the total for codes seen again at the end. */
class AppErrorTally {
    private val seen = LinkedHashMap<String, Pair<AppError, Int>>()
    fun record(error: AppError): Int {
        val count = (seen[error.code]?.second ?: 0) + 1
        seen[error.code] = (seen[error.code]?.first ?: error) to count
        return count
    }
    fun totals() = seen.values.filter { it.second > 1 }
    fun clear() = seen.clear()
}

/** Written to disk while a call runs and removed when it ends; still there at launch = the process was killed in a call. */
data class CallMarker(val callId: String, val channel: String, val user: String, val engine: String, val sdkVersion: String, val startedAtMs: Long) {
    fun encode() = listOf("v1", callId, channel, user, engine, sdkVersion, startedAtMs.toString()).joinToString("\t") { enc(it) }
    companion object {
        fun decode(text: String?): CallMarker? = runCatching {
            val p = text.orEmpty().split("\t").map { dec(it) }
            if (p.size != 7 || p[0] != "v1" || p[1].isBlank()) return null
            CallMarker(p[1], p[2], p[3], p[4], p[5], p[6].toLong())
        }.getOrNull()
    }
}

/** Where the queue keeps its text (a file on the device, a string in tests). */
interface TextStore {
    fun read(): String?
    fun write(text: String)
}

/**
 * app_error and abnormal_exit records survive a killed process: they are written to [store]
 * before being sent and removed once the collector answered. Capped at [cap] (oldest dropped).
 * Thread-safe; [drain] runs one sender at a time.
 */
class DurableTelemetryQueue(private val store: TextStore, private val cap: Int = 200) {
    enum class Outcome { SENT, REJECTED, RETRY }
    private val lock = Any()
    private val records: MutableList<TelemetryRecord> = synchronized(lock) {
        runCatching { store.read().orEmpty().lineSequence().filter { it.isNotBlank() }.mapNotNull(::decode).toMutableList() }
            .getOrDefault(mutableListOf())
    }
    private var draining = false

    fun add(batch: List<TelemetryRecord>) = synchronized(lock) {
        records += batch
        while (records.size > cap) records.removeAt(0)
        save()
    }
    fun pending(): List<TelemetryRecord> = synchronized(lock) { records.toList() }

    /** Sends everything queued; true when the queue was emptied (or already empty). */
    fun drain(send: (List<TelemetryRecord>) -> Outcome): Boolean {
        val batch = synchronized(lock) { if (draining) return false; draining = true; records.toList() }
        try {
            if (batch.isEmpty()) return true
            val outcome = send(batch)
            if (outcome == Outcome.RETRY) return false
            synchronized(lock) { records.removeAll { r -> batch.any { it === r } }; save() }
            return synchronized(lock) { records.isEmpty() }
        } finally { synchronized(lock) { draining = false } }
    }

    private fun save() = runCatching { store.write(records.joinToString("\n") { encode(it) }) }

    companion object {
        fun isDurable(record: TelemetryRecord) = record.body == Telemetry.APP_ERROR || record.attributes["reason"] == "abnormal_exit"
        // One line per record, tab-separated, every field URL-encoded (so tabs, newlines and '=' inside values are safe).
        private fun encode(r: TelemetryRecord) = (listOf("v1", r.severity, r.body, r.atEpochMs.toString()).map(::enc) +
            r.attributes.map { (k, v) -> enc(k) + "=" + enc(v) }).joinToString("\t")
        private fun decode(line: String): TelemetryRecord? = runCatching {
            val parts = line.split("\t")
            if (parts.size < 4 || dec(parts[0]) != "v1") return null
            val attributes = parts.drop(4).associate { field ->
                val (k, v) = field.split("=", limit = 2).also { require(it.size == 2) }
                dec(k) to dec(v)
            }
            TelemetryRecord(dec(parts[2]), dec(parts[3]).toLong(), attributes, dec(parts[1]))
        }.getOrNull()
    }
}

private fun enc(text: String): String = URLEncoder.encode(text, "UTF-8")
private fun dec(text: String): String = URLDecoder.decode(text, "UTF-8")
