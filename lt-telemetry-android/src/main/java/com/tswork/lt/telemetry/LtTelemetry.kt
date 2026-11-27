package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.StaticDevice
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.pow
import kotlin.random.Random

data class TelemetryConfig(
    /** The full URL (e.g. https://otel.example/v1/logs); null or blank turns telemetry off and every call is a no-op. */
    val logsUrl: String?,
    /** Called before every batch; today it returns `Authorization: Bearer <OTLP_TOKEN>`. */
    val headers: () -> Map<String, String> = { emptyMap() },
    /** Release builds pass true: a URL that is not https turns telemetry off (one log line). */
    val requireHttps: Boolean,
    /** `service.name`, e.g. "lt-call-demo"; no default on purpose. */
    val serviceName: String,
    val device: StaticDevice,
    /** Holds the record queue and the call marker; use a directory that is not backed up (Context.noBackupFilesDir). */
    val storageDir: File,
    /** Called only when delivery changes between working and failing; never gets the URL or a header. */
    val log: (String) -> Unit = {},
    /** Disk the queue may use; over it the oldest quality_second go first, app_error last ([TelemetryStore]). */
    val maxQueueBytes: Long = TelemetryStore.DEFAULT_MAX_BYTES,
    /** Records not delivered within this long are dropped (counted in the `telemetry/dropped` report). */
    val maxQueueAgeMs: Long = TelemetryStore.DEFAULT_MAX_AGE_MS,
)

/**
 * Posts [TelemetryRecord]s to the Collector, fire and forget. Every record is written to disk first ([TelemetryStore])
 * and sent from there on one background thread, so a crash or a killed process loses nothing: what is left goes out
 * when the next process starts (or on [flush]).
 *
 * Delivery: one segment (at most 200 records) per POST, most important lane first. 2xx deletes it; any other 4xx
 * drops it (it would block everything behind it); no answer, 408, 429 or 5xx keeps it and retries after
 * [RETRY_MS] doubling up to [MAX_RETRY_MS] with ±20% jitter, or after the server's `Retry-After`. While a retry is
 * pending, new records only go to disk. Dropped records are reported once delivery works again (`telemetry/dropped`).
 */
class LtTelemetry internal constructor(
    private val config: TelemetryConfig,
    private val retryMs: Long,
    private val maxRetryMs: Long,
    private val clock: () -> Long,
    private val jitter: () -> Double,
    poster: ((String) -> PostResult)?,
) {
    constructor(config: TelemetryConfig) : this(config, RETRY_MS, MAX_RETRY_MS, System::currentTimeMillis, { Random.nextDouble() }, null)

    /** [status] 0 = no answer; [retryAfterMs] from the `Retry-After` header. */
    internal data class PostResult(val status: Int, val retryAfterMs: Long? = null)

    private val url: String? = config.logsUrl?.trim()?.takeIf { it.isNotEmpty() }?.let {
        if (config.requireHttps && !it.startsWith("https://")) { config.log("遙測網址不是 https，已關閉遙測"); null } else it
    }
    val enabled get() = url != null

    private val post: (String) -> PostResult = poster ?: ::httpPost
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "lt-telemetry").apply { isDaemon = true }
    }
    private val store: TelemetryStore? = url?.let {
        TelemetryStore(File(config.storageDir, QUEUE_DIR), config.maxQueueBytes, config.maxQueueAgeMs, clock)
    }
    private val markerFile get() = File(config.storageDir, "call-marker.txt")

    // Guarded by `this`.
    private var telemetryOk: Boolean? = null
    private var failures = 0
    private var retry: ScheduledFuture<*>? = null
    /** The pending retry was set by the server (Retry-After); [flush] does not cut it short. */
    private var serverDelay = false
    private var uploadQueued = false

    init {
        if (store != null) executor.execute { importLegacyQueue(); upload() } // What the last process could not send.
    }

    /** Fire and forget: written to disk before it returns, sent in the background. Never throws. */
    fun send(records: List<TelemetryRecord>) {
        val store = store ?: return
        if (records.isEmpty()) return
        store.append(records)
        schedule(now = false)
    }

    /**
     * Try now: call when the network comes back or the app goes to the background. Cuts a client-side backoff short,
     * but not a server's Retry-After.
     */
    fun flush() { if (store != null) schedule(now = true) }

    /** The on-disk call marker ([CallMarker]); null clears it. Survives the process. */
    fun writeCallMarker(text: String?) {
        if (text == null) markerFile.delete() else TelemetryStore.writeAtomically(markerFile, text)
    }
    fun readCallMarker(): String? = markerFile.takeIf { it.exists() }?.readText()

    /** Runs [block] after everything queued on the telemetry thread so far (tests). */
    internal fun <T> onWorker(block: () -> T): T = executor.submit<T> { block() }.get(10, TimeUnit.SECONDS)
    internal val queue get() = store

    private fun schedule(now: Boolean) {
        synchronized(this) {
            val pending = retry
            if (pending != null) {
                if (!now || serverDelay) return
                pending.cancel(false); retry = null
            }
            if (uploadQueued) return
            uploadQueued = true
        }
        executor.execute { upload() }
    }

    /** Sends batch after batch until the queue is empty or one fails; on the telemetry thread only. */
    private fun upload() {
        val store = store ?: return
        synchronized(this) { uploadQueued = false; if (retry != null) return }
        while (true) {
            val batch = store.next() ?: return
            val result = post(Telemetry.logsJson(batch.records, config.device, config.serviceName, observedEpochMs = clock()))
            val ok = result.status in 200..299
            logOutcome(ok)
            when {
                ok -> {
                    store.complete(batch, sent = true)
                    synchronized(this) { failures = 0 }
                    // Losses are reported once there is a working path to report them on.
                    val dropped = store.takeDropped()
                    if (dropped.isNotEmpty()) store.append(listOf(droppedReport(dropped)))
                }
                retryable(result.status) -> {
                    store.release(batch)
                    backOff(result.retryAfterMs)
                    return
                }
                // A permanent rejection (bad token, bad payload) would block every later record, so that batch is dropped.
                else -> store.complete(batch, sent = false)
            }
        }
    }

    private fun backOff(retryAfterMs: Long?) = synchronized(this) {
        failures++
        val delay = if (retryAfterMs != null) retryAfterMs.coerceIn(retryMs, MAX_RETRY_AFTER_MS)
            else backoffDelay(failures, retryMs, maxRetryMs, jitter())
        serverDelay = retryAfterMs != null
        retry = executor.schedule({ synchronized(this) { retry = null; serverDelay = false }; upload() }, delay, TimeUnit.MILLISECONDS)
    }

    private fun logOutcome(ok: Boolean) {
        // Sent every few seconds, so only a change of outcome is logged.
        val changed = synchronized(this) { (ok != telemetryOk).also { telemetryOk = ok } }
        if (changed) config.log(if (ok) "遙測已送達 lt-observability" else "遙測上報失敗（不影響通話），稍後重送")
    }

    private fun droppedReport(dropped: Map<TelemetryStore.Drop, Int>) = Telemetry.appEvent(
        LABEL_TELEMETRY, "telemetry records dropped", REASON_DROPPED, clock(),
        extra = dropped.entries.associate { (reason, n) -> "dropped_${reason.code}" to n.toString() })

    /** Moves app_error / abnormal_exit left in the previous version's telemetry-durable.txt into the queue. */
    private fun importLegacyQueue() {
        val store = store ?: return
        val legacy = File(config.storageDir, LEGACY_DURABLE_FILE)
        if (!legacy.exists()) return
        runCatching {
            store.append(legacy.readLines().filter { it.isNotBlank() }.mapNotNull(TelemetryStore::decode))
            legacy.delete()
        }
    }

    /** HTTP status (0 when there was no answer) and the Retry-After delay, if any. */
    private fun httpPost(body: String): PostResult = runCatching {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            config.headers().forEach { (k, v) -> connection.setRequestProperty(k, v) }
            connection.outputStream.use { it.write(body.toByteArray()) }
            val status = connection.responseCode
            PostResult(status, parseRetryAfter(connection.getHeaderField("Retry-After"), clock()))
        } finally { connection.disconnect() }
    }.getOrDefault(PostResult(0))

    companion object {
        const val RETRY_MS = 10_000L
        const val MAX_RETRY_MS = 5 * 60_000L
        /** A server asking for longer than this is capped (a stuck header must not silence telemetry for days). */
        const val MAX_RETRY_AFTER_MS = 60 * 60_000L
        const val QUEUE_DIR = "telemetry-queue"
        /** Where versions before the disk queue kept app_error / abnormal_exit; imported once. */
        const val LEGACY_DURABLE_FILE = "telemetry-durable.txt"
        const val LABEL_TELEMETRY = "telemetry"
        const val REASON_DROPPED = "dropped"
        private const val TIMEOUT_MS = 5_000

        internal fun retryable(status: Int) = status == 0 || status == 408 || status == 429 || status >= 500

        /** [base] × 2^(failures−1), capped at [max], then ±20% ([unit] is a random number in [0, 1)). */
        internal fun backoffDelay(failures: Int, base: Long, max: Long, unit: Double): Long {
            val raw = (base * 2.0.pow((failures - 1).coerceIn(0, 30))).coerceAtMost(max.toDouble())
            return (raw * (0.8 + 0.4 * unit)).toLong()
        }

        /** `Retry-After: <seconds>` or an HTTP date; null when absent or unreadable. */
        internal fun parseRetryAfter(value: String?, nowMs: Long): Long? {
            val text = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            text.toLongOrNull()?.let { return (it * 1000).coerceAtLeast(0) }
            return runCatching {
                (ZonedDateTime.parse(text, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - nowMs).coerceAtLeast(0)
            }.getOrNull()
        }
    }
}
