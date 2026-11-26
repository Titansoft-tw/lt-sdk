package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.StaticDevice
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

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
    /** Holds the durable queue and the call marker; use a directory that is not backed up (Context.noBackupFilesDir). */
    val storageDir: File,
    /** Called only when delivery changes between working and failing; never gets the URL or a header. */
    val log: (String) -> Unit = {},
)

/**
 * Posts [TelemetryRecord]s to the Collector, fire and forget, from one background thread. Records that cannot be sent
 * wait in memory (newest [MAX_UNSENT] kept) and go out with the next batch; app_error and abnormal_exit go through a
 * file first ([DurableTelemetryQueue]) so a killed process sends them at the next launch.
 */
class LtTelemetry internal constructor(private val config: TelemetryConfig, private val retryMs: Long) {
    constructor(config: TelemetryConfig) : this(config, RETRY_MS)

    private val url: String? = config.logsUrl?.trim()?.takeIf { it.isNotEmpty() }?.let {
        if (config.requireHttps && !it.startsWith("https://")) { config.log("遙測網址不是 https，已關閉遙測"); null } else it
    }
    val enabled get() = url != null

    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "lt-telemetry").apply { isDaemon = true }
    }
    private var telemetryOk: Boolean? = null
    private val unsent = ArrayDeque<TelemetryRecord>()
    private var retryScheduled = false
    private val durable by lazy { DurableTelemetryQueue(FileStore(File(config.storageDir, "telemetry-durable.txt"))) }
    @Volatile private var durableRetry = false
    private val markerFile get() = File(config.storageDir, "call-marker.txt")

    init { if (url != null) executor.execute { drainDurable() } } // What the last process could not send.

    /** Fire and forget: never blocks or throws. */
    fun send(records: List<TelemetryRecord>) {
        url ?: return
        val (lasting, rest) = records.partition(DurableTelemetryQueue::isDurable)
        if (lasting.isNotEmpty()) { durable.add(lasting); executor.execute { drainDurable() } }
        if (rest.isEmpty()) return
        // While a retry is pending the collector is known to be unreachable; new records just wait for it.
        val idle = synchronized(unsent) { unsent.addAll(rest); trimUnsent(); !retryScheduled }
        if (idle) executor.execute { sendAll() }
    }

    /** The on-disk call marker ([CallMarker]); null clears it. Survives the process. */
    fun writeCallMarker(text: String?) {
        if (text == null) markerFile.delete() else writeAtomically(markerFile, text)
    }
    fun readCallMarker(): String? = markerFile.takeIf { it.exists() }?.readText()

    /** Sends the queue oldest first in small chunks; stops at the first failure and retries later on its own. */
    private fun sendAll() {
        while (true) {
            // A run queued before a failure must not send ahead of the scheduled retry.
            val batch = synchronized(unsent) { if (retryScheduled) return; List(minOf(unsent.size, CHUNK)) { unsent.removeFirst() } }
            if (batch.isEmpty()) return
            val status = post(batch)
            val ok = status in 200..299
            // Sent every few seconds, so only a change of outcome is logged.
            if (ok != telemetryOk) { telemetryOk = ok; config.log(if (ok) "遙測已送達 lt-observability" else "遙測上報失敗（不影響通話）") }
            // A permanent rejection (bad token, bad payload) would block every later record, so that chunk is dropped.
            if (!ok && retryable(status)) {
                synchronized(unsent) { unsent.addAll(0, batch); trimUnsent(); retryScheduled = true }
                executor.schedule({ synchronized(unsent) { retryScheduled = false }; sendAll() }, retryMs, TimeUnit.MILLISECONDS)
                return
            }
        }
    }

    private fun drainDurable() {
        val done = durable.drain { batch ->
            val status = post(batch)
            when {
                status in 200..299 -> DurableTelemetryQueue.Outcome.SENT
                retryable(status) -> DurableTelemetryQueue.Outcome.RETRY
                else -> DurableTelemetryQueue.Outcome.REJECTED
            }
        }
        if (!done && !durableRetry) {
            durableRetry = true
            executor.schedule({ durableRetry = false; drainDurable() }, retryMs * 3, TimeUnit.MILLISECONDS)
        }
    }

    /** HTTP status, 0 when there was no answer. */
    private fun post(batch: List<TelemetryRecord>): Int = runCatching {
        val body = Telemetry.logsJson(batch, config.device, config.serviceName).toByteArray()
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            config.headers().forEach { (k, v) -> connection.setRequestProperty(k, v) }
            connection.outputStream.use { it.write(body) }
            connection.responseCode
        } finally { connection.disconnect() }
    }.getOrDefault(0)

    private fun trimUnsent() { while (unsent.size > MAX_UNSENT) unsent.removeFirst() }

    private class FileStore(private val file: File) : TextStore {
        override fun read() = file.takeIf { it.exists() }?.readText()
        override fun write(text: String) { if (text.isEmpty()) file.delete() else writeAtomically(file, text) }
    }

    companion object {
        /** About 30 minutes of one leg at one sample per second. */
        const val MAX_UNSENT = 1_800
        const val CHUNK = 200
        const val RETRY_MS = 10_000L
        private const val TIMEOUT_MS = 5_000
        private fun retryable(status: Int) = status == 0 || status == 408 || status == 429 || status >= 500

        private fun writeAtomically(file: File, text: String) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        }
    }
}
