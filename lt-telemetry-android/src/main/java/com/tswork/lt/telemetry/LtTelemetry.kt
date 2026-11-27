package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.StaticDevice
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.CountDownLatch
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
    /**
     * When the previous process died within [STARTUP_WINDOW_MS] of starting (a crash loop at launch), the constructor
     * waits up to this long for the first delivery attempt, so the records about that crash go out before this process
     * can crash too (Sentry's app-start crash detection). 0 turns it off. Keep it well under the ANR limit.
     */
    val startupCrashWaitMs: Long = 2_000,
    /**
     * Called on the telemetry thread whenever records are left waiting for a retry, e.g. to schedule a WorkManager job
     * that calls [LtTelemetry.drain] once the network is back, even if the app is not opened again. Must not block.
     */
    val onBacklog: () -> Unit = {},
    /**
     * Remote telemetry config ([RemoteTelemetryConfig]): null derives `<base>/config/telemetry.json` from a [logsUrl]
     * ending in `/v1/logs`; blank turns it off. Fetched with the same [headers].
     */
    val configUrl: String? = null,
    /** `debug` or `release`: what the config's rules match `build` against. */
    val buildType: String = "release",
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
    private val target = ConfigTarget(config.device.platform, config.device.appVersion, config.buildType)
    private val configUrl: String? = url?.let { logs ->
        when {
            config.configUrl == null -> logs.trimEnd('/').takeIf { it.endsWith("/v1/logs") }?.removeSuffix("/v1/logs")?.plus(CONFIG_PATH)
            config.configUrl.isBlank() -> null
            else -> config.configUrl.trim()
        }
    }
    private val configFile get() = File(config.storageDir, CONFIG_FILE)
    private val etagFile get() = File(config.storageDir, CONFIG_ETAG_FILE)
    /** This install's rollout bucket (0–99): local only, never sent. */
    private val bucket: Int by lazy {
        val file = File(config.storageDir, BUCKET_FILE)
        runCatching { file.readText().trim().toInt().takeIf { it in 0..99 } }.getOrNull()
            ?: Random.nextInt(100).also { runCatching { TelemetryStore.writeAtomically(file, it.toString()) } }
    }

    /** The settings in effect: the last good remote config (from disk at start), or the defaults. */
    @Volatile var settings: TelemetrySettings = if (configUrl == null) TelemetrySettings() else
        runCatching { configFile.takeIf { it.exists() }?.readText()?.let { RemoteTelemetryConfig.parse(it, target, bucket) } }.getOrNull()
            ?: TelemetrySettings()
        private set
    private var lastConfigFetch = 0L

    private val store: TelemetryStore? = url?.let {
        val remote = settings.version != null
        TelemetryStore(File(config.storageDir, QUEUE_DIR), if (remote) settings.queueMaxBytes else config.maxQueueBytes,
            if (remote) settings.queueMaxAgeMs else config.maxQueueAgeMs, clock)
    }
    private val markerFile get() = File(config.storageDir, "call-marker.txt")
    private val heldFile get() = File(config.storageDir, HELD_FILE)
    private val launchFile get() = File(config.storageDir, LAUNCH_FILE)

    // Guarded by `this`.
    private var telemetryOk: Boolean? = null
    private var failures = 0
    private var retry: ScheduledFuture<*>? = null
    /** The pending retry was set by the server (Retry-After); [flush] does not cut it short. */
    private var serverDelay = false
    private var uploadQueued = false
    /** Released at the end of the next upload pass ([drain], the startup wait). */
    private val passWaiters = mutableListOf<CountDownLatch>()

    init {
        if (store != null) {
            // The launch marker lives for STARTUP_WINDOW_MS: still there at the next start = that process died early.
            val crashedAtLaunch = config.startupCrashWaitMs > 0 && launchFile.exists()
            runCatching { TelemetryStore.writeAtomically(launchFile, clock().toString()) }
            executor.schedule({ runCatching { launchFile.delete() } }, STARTUP_WINDOW_MS, TimeUnit.MILLISECONDS)
            val firstPass = CountDownLatch(1).also { synchronized(this) { passWaiters += it } }
            executor.execute { importLegacyQueue(); upload() } // What the last process could not send.
            refreshConfig(0)
            if (crashedAtLaunch) {
                config.log("上次啟動後很快就結束，先送出遙測再繼續")
                runCatching { firstPass.await(config.startupCrashWaitMs, TimeUnit.MILLISECONDS) }
            }
        }
    }

    /** Fire and forget: written to disk before it returns, sent in the background. Never throws. */
    fun send(records: List<TelemetryRecord>) {
        val store = store ?: return
        val now = settings
        if (!now.enabled || records.isEmpty()) return
        val kept = records.filter { r ->
            r.body != Telemetry.SDK_EVENT || r.attributes["label"] !in now.dropLabels || TelemetryStore.Lane.of(r) == TelemetryStore.Lane.CRITICAL
        }.map { r -> now.version?.let { r.copy(attributes = r.attributes + (CONFIG_VERSION to it.toString())) } ?: r }
        if (kept.isEmpty()) return
        store.append(kept)
        schedule(now = false)
    }

    /**
     * Fetches the remote config in the background unless the last fetch was less than [minIntervalMs] ago (the app:
     * every call start with a short interval, coming to the foreground with 15 minutes). Sends `If-None-Match`, so an
     * unchanged file costs a 304. What it changes applies from the next record on; queue limits from the next launch.
     */
    fun refreshConfig(minIntervalMs: Long) {
        configUrl ?: return
        synchronized(this) {
            val now = clock()
            if (lastConfigFetch != 0L && now - lastConfigFetch < minIntervalMs) return
            lastConfigFetch = now
        }
        executor.execute { fetchConfig() }
    }

    /**
     * Try now: call when the network comes back or the app goes to the background. Cuts a client-side backoff short,
     * but not a server's Retry-After.
     */
    fun flush() { if (store != null) schedule(now = true) }

    /**
     * Sends what is queued now and waits up to [timeoutMs] for that pass (blocking: call it from a worker, never the
     * main thread). True when the queue is empty afterwards. False at once while the server's Retry-After runs.
     */
    fun drain(timeoutMs: Long): Boolean {
        val store = store ?: return true
        val latch = CountDownLatch(1)
        synchronized(this) {
            if (retry != null && serverDelay) return false
            passWaiters += latch
        }
        schedule(now = true)
        runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }
        return store.isEmpty
    }

    /**
     * Records the app holds back until their call_id is final (lt-call-demo's outbox), kept on disk so a crash before
     * that does not lose them: rewritten whenever the held set changes, empty clears it. [takeHeld] at the next launch
     * returns them once.
     */
    fun writeHeld(records: List<TelemetryRecord>) {
        if (store == null) return
        runCatching {
            if (records.isEmpty()) heldFile.delete()
            else TelemetryStore.writeAtomically(heldFile, records.joinToString("\n") { TelemetryStore.encode(it) })
        }
    }
    fun takeHeld(): List<TelemetryRecord> {
        if (!heldFile.exists()) return emptyList()
        val records = runCatching { heldFile.readLines().filter { it.isNotBlank() }.mapNotNull(TelemetryStore::decode) }.getOrDefault(emptyList())
        runCatching { heldFile.delete() }
        return records
    }

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
        try { uploadPass() } finally {
            val waiters = synchronized(this) { passWaiters.toList().also { passWaiters.clear() } }
            waiters.forEach { it.countDown() }
        }
    }

    private fun uploadPass() {
        val store = store ?: return
        synchronized(this) { uploadQueued = false; if (retry != null) return }
        if (!settings.enabled) return // Remote kill switch: the queue waits (until it expires).
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
                    runCatching { config.onBacklog() }
                    return
                }
                // A permanent rejection (bad token, bad payload) would block every later record, so that batch is dropped.
                else -> store.complete(batch, sent = false)
            }
        }
    }

    private fun backOff(retryAfterMs: Long?) = synchronized(this) {
        failures++
        val remote = settings.takeIf { it.version != null }
        val base = remote?.retryBaseMs ?: retryMs
        val delay = if (retryAfterMs != null) retryAfterMs.coerceIn(base, MAX_RETRY_AFTER_MS)
            else backoffDelay(failures, base, remote?.retryMaxMs ?: maxRetryMs, jitter())
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

    /** On the telemetry thread. Keeps the last good config on disk; a bad or missing file changes nothing. */
    private fun fetchConfig() {
        val target = configUrl ?: return
        val result = runCatching {
            val connection = URL(target).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = TIMEOUT_MS
                connection.readTimeout = TIMEOUT_MS
                config.headers().forEach { (k, v) -> connection.setRequestProperty(k, v) }
                runCatching { etagFile.readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() && configFile.exists() }
                    ?.let { connection.setRequestProperty("If-None-Match", it) }
                val status = connection.responseCode
                if (status != 200) return
                val body = connection.inputStream.use { it.readBytes() }.takeIf { it.size <= MAX_CONFIG_BYTES }?.decodeToString() ?: return
                body to connection.getHeaderField("ETag")
            } finally { connection.disconnect() }
        }.getOrNull() ?: return
        val parsed = RemoteTelemetryConfig.parse(result.first, this.target, bucket) ?: run { config.log("遙測設定檔格式不符，沿用目前設定"); return }
        runCatching {
            TelemetryStore.writeAtomically(configFile, result.first)
            if (result.second.isNullOrBlank()) etagFile.delete() else TelemetryStore.writeAtomically(etagFile, result.second!!)
        }
        if (parsed.version != settings.version) config.log("已套用遙測設定 v${parsed.version}")
        settings = parsed
    }

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
        const val HELD_FILE = "telemetry-held.txt"
        const val CONFIG_PATH = "/config/telemetry.json"
        const val CONFIG_FILE = "telemetry-config.json"
        const val CONFIG_ETAG_FILE = "telemetry-config.etag"
        const val BUCKET_FILE = "telemetry-bucket.txt"
        /** Attribute on every record sent under a remote config: its `version`. */
        const val CONFIG_VERSION = "config_version"
        private const val MAX_CONFIG_BYTES = 64 * 1024
        const val LAUNCH_FILE = "telemetry-launch.txt"
        /** A process that ends within this long of starting counts as a crash at launch ([TelemetryConfig.startupCrashWaitMs]). */
        const val STARTUP_WINDOW_MS = 5_000L
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
