package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.StaticDevice
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/** The transport against a local HTTP server: delivery, headers, retry and backoff, permanent rejection, the disk queue across restarts. */
class LtTelemetryTest {
    private class Hit(val body: String, val auth: String?, val atMs: Long = System.currentTimeMillis())
    private val hits = CopyOnWriteArrayList<Hit>()
    /** Status codes to answer with, in order; 200 once they run out. */
    private val statuses = CopyOnWriteArrayList<Int>()
    /** Retry-After values sent with the answers above, in the same order (null = none). */
    private val retryAfters = CopyOnWriteArrayList<String?>()
    /** GET <base>/config/telemetry.json: the file served (null = 404) and the If-None-Match each request sent. */
    @Volatile private var configBody: String? = null
    @Volatile private var configEtag = "\"v1\""
    private val configHits = CopyOnWriteArrayList<String?>()
    // Unit tests compile against android.jar, which has no com.sun.net.httpserver: a minimal HTTP/1.1 server instead.
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    init {
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                socket.use { s ->
                    val input = s.getInputStream()
                    val headers = generateSequence { readLine(input) }.takeWhile { it.isNotEmpty() }.toList()
                    fun header(name: String) = headers.firstOrNull { it.startsWith("$name:", ignoreCase = true) }?.substringAfter(':')?.trim()
                    if (headers.firstOrNull()?.startsWith("GET /config/telemetry.json") == true) {
                        configHits += header("If-None-Match")
                        val served = configBody
                        val reply = when {
                            served == null -> "HTTP/1.1 404 X\r\nContent-Length: 0\r\n"
                            header("If-None-Match") == configEtag -> "HTTP/1.1 304 X\r\nETag: $configEtag\r\nContent-Length: 0\r\n"
                            else -> "HTTP/1.1 200 X\r\nETag: $configEtag\r\nContent-Length: ${served.toByteArray().size}\r\n"
                        }
                        s.getOutputStream().write("${reply}Connection: close\r\n\r\n${if (reply.startsWith("HTTP/1.1 200")) served else ""}".toByteArray())
                        return@use
                    }
                    val body = ByteArray(header("Content-Length")?.toInt() ?: 0).also { var n = 0; while (n < it.size) n += input.read(it, n, it.size - n) }
                    hits += Hit(body.decodeToString(), header("Authorization"))
                    val status = if (statuses.isEmpty()) 200 else statuses.removeAt(0)
                    val retryAfter = if (retryAfters.isEmpty()) null else retryAfters.removeAt(0)
                    val extra = retryAfter?.let { "Retry-After: $it\r\n" }.orEmpty()
                    s.getOutputStream().write("HTTP/1.1 $status X\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                }
            }
        }
    }
    private fun readLine(input: java.io.InputStream): String? {
        val line = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (line.isEmpty()) null else line.toString()
            if (c == '\n'.code) return line.toString().trimEnd('\r')
            line.append(c.toChar())
        }
    }
    private val url = "http://127.0.0.1:${server.localPort}/v1/logs"
    private val dir: File = Files.createTempDirectory("lt-telemetry").toFile()
    private val device = StaticDevice("android", "15", "1.0", "Google Pixel 8", "Google")

    @After fun stop() { server.close(); dir.deleteRecursively() }

    private fun telemetry(url: String? = this.url, requireHttps: Boolean = false, retryMs: Long = 50, log: (String) -> Unit = {}) = LtTelemetry(
        TelemetryConfig(url, headers = { mapOf("Authorization" to "Bearer t0k") }, requireHttps = requireHttps,
            serviceName = "unit-test", device = device, storageDir = dir, log = log),
        retryMs = retryMs, maxRetryMs = retryMs * 4, clock = System::currentTimeMillis, jitter = { 0.5 }, poster = null)
    private val down = "http://127.0.0.1:1/v1/logs" // Nothing listens: status 0.
    private fun uids(body: String) = Regex(""""log\.record\.uid","value":\{"stringValue":"([^"]+)"""").findAll(body).map { it.groupValues[1] }.toList()

    private fun eventually(what: String, check: () -> Boolean) {
        val until = System.currentTimeMillis() + 5_000
        while (!check()) { if (System.currentTimeMillis() > until) throw AssertionError("timed out: $what"); Thread.sleep(10) }
    }

    private fun event(reason: String) = Telemetry.appEvent("app_state", "app $reason", reason, 1L)

    @Test fun deliversWithHeadersServiceNameAndDeviceFields() {
        val logs = CopyOnWriteArrayList<String>()
        telemetry(log = { logs += it }).send(listOf(event("background")))
        eventually("one post") { hits.size == 1 }
        val hit = hits.single()
        assertEquals("Bearer t0k", hit.auth)
        assertTrue(hit.body.contains(""""service.name","value":{"stringValue":"unit-test"}"""))
        assertTrue(hit.body.contains(""""device_model","value":{"stringValue":"Google Pixel 8"}"""))
        eventually("log line") { logs.isNotEmpty() }
        assertFalse(logs.any { it.contains("127.0.0.1") || it.contains("t0k") })
    }

    @Test fun aServerErrorIsRetriedInOrderAndARejectionIsDropped() {
        statuses += 503
        val t = telemetry()
        t.send(listOf(event("a")))
        eventually("retry") { hits.size == 2 }
        assertTrue(hits[1].body.contains("\"a\""))
        t.send(listOf(event("b")))
        eventually("third post") { hits.size == 3 }
        assertTrue(hits[2].body.contains("\"b\"") && !hits[2].body.contains("\"a\""))

        statuses += 400
        t.send(listOf(event("c")))
        eventually("rejected post") { hits.size == 4 }
        Thread.sleep(200) // Longer than the retry delay: a 400 is not sent again.
        assertEquals(4, hits.size)
    }

    @Test fun everyRecordSurvivesARestartAndErrorsGoFirst() {
        val sample = Telemetry.qualitySecond(TelemetryLeg("c-1", "room", "1001", engine = "agora"), AudioMetrics(rttMs = 10.0), 1L)
        val error = Telemetry.appError(AppError(ErrorDomain.API, "http_503"), "idle", 1, 2L)
        val offline = telemetry(url = down, retryMs = 60_000)
        offline.send(listOf(sample, event("background")))
        offline.send(listOf(error))
        offline.onWorker { } // The first attempt failed; everything is on disk.
        assertFalse(offline.queue!!.isEmpty)
        telemetry() // Next launch (the process died), collector reachable.
        eventually("all sent at launch") { hits.size == 3 }
        assertTrue(hits[0].body.contains("http_503")) // app_error first.
        assertTrue(hits[1].body.contains("\"background\""))
        assertTrue(hits[2].body.contains("quality_second"))
        assertTrue(hits.all { it.body.contains("\"observedTimeUnixNano\"") })
        eventually("queue empty") { dir.resolve(LtTelemetry.QUEUE_DIR).listFiles()!!.none { it.name.endsWith(".log") } }
    }

    @Test fun theLegacyDurableFileIsImportedOnce() {
        val legacy = Telemetry.appError(AppError(ErrorDomain.APP_EXIT, "exit_low_memory", fatal = true), "in_call", 1, 5L)
        File(dir, LtTelemetry.LEGACY_DURABLE_FILE).writeText(TelemetryStore.encode(legacy) + "\n")
        telemetry()
        eventually("legacy sent") { hits.any { it.body.contains("exit_low_memory") } }
        assertFalse(File(dir, LtTelemetry.LEGACY_DURABLE_FILE).exists())
    }

    @Test fun aRetryKeepsTheRecordUidSoThePlatformCanDeDuplicate() {
        statuses += 503
        telemetry().send(listOf(event("a")))
        eventually("retry") { hits.size == 2 }
        assertEquals(1, uids(hits[0].body).size)
        assertEquals(uids(hits[0].body), uids(hits[1].body))
    }

    @Test fun retryAfterIsHonouredAndFlushDoesNotCutItShort() {
        statuses += 429; retryAfters += "1"
        val t = telemetry()
        t.send(listOf(event("a")))
        eventually("first post") { hits.size == 1 }
        t.flush()
        t.send(listOf(event("b"))) // Waits on disk for the retry.
        eventually("retry") { hits.size >= 2 } // b follows right after, so the count can jump straight to 3.
        assertTrue(hits[1].atMs - hits[0].atMs >= 900)
        eventually("b too") { hits.any { it.body.contains("\"b\"") } }
    }

    @Test fun flushCutsAClientBackoffShort() {
        val answers = CopyOnWriteArrayList(listOf(0)) // Offline once, then delivered.
        val posts = CopyOnWriteArrayList<String>()
        val t = LtTelemetry(TelemetryConfig(url, requireHttps = false, serviceName = "unit-test", device = device, storageDir = dir),
            retryMs = 60_000, maxRetryMs = 60_000, clock = System::currentTimeMillis, jitter = { 0.5 },
            poster = { body -> posts += body; LtTelemetry.PostResult(if (answers.isEmpty()) 200 else answers.removeAt(0)) })
        t.send(listOf(event("a")))
        t.onWorker { } // Failed; the next try is a minute away.
        assertEquals(1, posts.size)
        t.flush() // The network is back.
        eventually("sent on flush") { posts.size == 2 }
        assertTrue(t.onWorker { t.queue!!.isEmpty })
    }

    @Test fun dropsAreReportedOnceDeliveryWorks() {
        statuses += 400
        val t = telemetry()
        t.send(listOf(event("rejected")))
        eventually("rejected post") { hits.size == 1 }
        t.send(listOf(event("next")))
        eventually("drop report") { hits.any { it.body.contains("\"dropped_rejected\",\"value\":{\"stringValue\":\"1\"}") } }
        val report = hits.first { it.body.contains("dropped_rejected") }.body
        assertTrue(report.contains("\"label\",\"value\":{\"stringValue\":\"telemetry\"}"))
    }

    @Test fun backoffDoublesUpToTheCapWithJitterAndRetryAfterParses() {
        assertEquals(10_000L, LtTelemetry.backoffDelay(1, 10_000, 300_000, 0.5))
        assertEquals(20_000L, LtTelemetry.backoffDelay(2, 10_000, 300_000, 0.5))
        assertEquals(300_000L, LtTelemetry.backoffDelay(20, 10_000, 300_000, 0.5))
        assertEquals(8_000L, LtTelemetry.backoffDelay(1, 10_000, 300_000, 0.0))
        assertEquals(11_999L, LtTelemetry.backoffDelay(1, 10_000, 300_000, 0.99999))
        assertEquals(120_000L, LtTelemetry.parseRetryAfter("120", 0))
        assertEquals(30_000L, LtTelemetry.parseRetryAfter("Wed, 21 Oct 2015 07:28:30 GMT", 1445412480000L))
        assertNull(LtTelemetry.parseRetryAfter("soon", 0))
        assertNull(LtTelemetry.parseRetryAfter(null, 0))
        assertTrue(LtTelemetry.retryable(0) && LtTelemetry.retryable(429) && LtTelemetry.retryable(503))
        assertFalse(LtTelemetry.retryable(400) || LtTelemetry.retryable(401))
    }

    @Test fun heldRecordsSurviveTheProcessAndAreReturnedOnce() {
        val held = listOf(event("held-1"), Telemetry.appError(AppError(ErrorDomain.RTC, "agora_error_17"), "joining", 1, 3L))
        telemetry().writeHeld(held)
        val next = telemetry()
        assertEquals(held.map { it.body to it.atEpochMs }, next.takeHeld().map { it.body to it.atEpochMs })
        assertTrue(next.takeHeld().isEmpty())
        next.writeHeld(held); next.writeHeld(emptyList()) // Sent normally: cleared.
        assertTrue(telemetry().takeHeld().isEmpty())
    }

    @Test fun drainSendsNowAndReportsWhetherTheQueueIsEmpty() {
        val answers = CopyOnWriteArrayList(listOf(0, 0)) // Offline twice, then delivered.
        val backlog = CopyOnWriteArrayList<Long>()
        val t = LtTelemetry(TelemetryConfig(url, requireHttps = false, serviceName = "unit-test", device = device, storageDir = dir,
            onBacklog = { backlog += System.currentTimeMillis() }),
            retryMs = 60_000, maxRetryMs = 60_000, clock = System::currentTimeMillis, jitter = { 0.5 },
            poster = { LtTelemetry.PostResult(if (answers.isEmpty()) 200 else answers.removeAt(0)) })
        t.send(listOf(event("a")))
        t.onWorker { }
        assertEquals(1, backlog.size) // Left waiting: the app can schedule a job.
        assertFalse(t.drain(5_000)) // Still offline.
        assertTrue(t.drain(5_000))
        assertTrue(t.drain(5_000)) // Nothing left.
    }

    @Test fun aProcessThatDiedAtLaunchMakesTheNextStartWaitForTheFirstSend() {
        val logs = CopyOnWriteArrayList<String>()
        val posted = java.util.concurrent.CountDownLatch(1)
        fun start() = LtTelemetry(TelemetryConfig(url, requireHttps = false, serviceName = "unit-test", device = device, storageDir = dir,
            log = { logs += it }, startupCrashWaitMs = 3_000),
            retryMs = 50, maxRetryMs = 200, clock = System::currentTimeMillis, jitter = { 0.5 },
            poster = { Thread.sleep(300); posted.countDown(); LtTelemetry.PostResult(200) })
        start().send(listOf(Telemetry.appError(AppError(ErrorDomain.APP_EXIT, "exit_crash", fatal = true), "idle", 1, 1L)))
        // That process "died" within the launch window: its marker is still there.
        assertTrue(File(dir, LtTelemetry.LAUNCH_FILE).exists())
        start() // Blocks until its first pass sent the leftover record.
        assertEquals(0, posted.count)
        assertTrue(logs.any { it.contains("很快就結束") })
    }

    @Test fun remoteConfigIsFetchedCachedAndAppliedWithItsVersion() {
        configBody = """{"schema":1,"version":4,"telemetry":{"drop_labels":["mic"],"batch_records":7}}"""
        val t = telemetry()
        eventually("config applied") { t.settings.version == 4 }
        assertEquals(7, t.settings.batchRecords)
        t.send(listOf(Telemetry.appEvent("mic", "x", "silenced", 1L), event("kept"),
            Telemetry.appError(AppError(ErrorDomain.AUDIO, "x"), "idle", 1, 2L)))
        eventually("two posts") { hits.size == 2 }
        val bodies = hits.joinToString { it.body }
        assertFalse(bodies.contains("\"silenced\"")) // Dropped by label.
        assertTrue(bodies.contains("\"kept\"") && bodies.contains("app_error"))
        assertTrue(hits.all { it.body.contains(""""config_version","value":{"stringValue":"4"}""") })
        // Next launch: the cached file applies at once, and the fetch sends its ETag (answered 304).
        configBody = """{"schema":1,"version":5}"""
        val next = telemetry()
        assertEquals(4, next.settings.version)
        eventually("conditional fetch") { configHits.contains("\"v1\"") }
        assertEquals(4, next.settings.version)
    }

    @Test fun refreshIsThrottledAndABadFileKeepsTheLastGoodSettings() {
        configBody = """{"schema":1,"version":1}"""
        val t = telemetry()
        eventually("first fetch") { t.settings.version == 1 }
        t.refreshConfig(60_000) // Too soon.
        t.onWorker { }
        assertEquals(1, configHits.size)
        configBody = "{broken"; configEtag = "\"v2\""
        t.refreshConfig(0)
        t.onWorker { }
        assertEquals(2, configHits.size)
        assertEquals(1, t.settings.version)
    }

    @Test fun theKillSwitchStopsSendingAndUploading() {
        configBody = """{"schema":1,"version":9,"telemetry":{"enabled":false}}"""
        val t = telemetry()
        eventually("disabled") { !t.settings.enabled }
        t.send(listOf(event("x")))
        t.onWorker { }
        Thread.sleep(100)
        assertTrue(hits.isEmpty())
    }

    @Test fun offWithoutUrlOrWithHttpWhenHttpsIsRequired() {
        val logs = CopyOnWriteArrayList<String>()
        val insecure = telemetry(requireHttps = true, log = { logs += it })
        assertFalse(insecure.enabled)
        assertEquals(1, logs.size)
        assertFalse(logs.single().contains("127.0.0.1"))
        assertFalse(telemetry(url = " ").enabled)
        insecure.send(listOf(event("x")))
        Thread.sleep(100)
        assertTrue(hits.isEmpty())
    }

    @Test fun anExplicitHttpConfigUrlIsNotFetchedWhenHttpsIsRequired() {
        val logs = CopyOnWriteArrayList<String>()
        val t = LtTelemetry(TelemetryConfig("https://otel.invalid/v1/logs", headers = { mapOf("Authorization" to "Bearer t0k") },
            requireHttps = true, serviceName = "unit-test", device = device, storageDir = dir, log = { logs += it },
            configUrl = "http://127.0.0.1:${server.localPort}/config/telemetry.json"),
            retryMs = 50, maxRetryMs = 200, clock = System::currentTimeMillis, jitter = { 0.5 }, poster = { LtTelemetry.PostResult(200) })
        t.refreshConfig(0)
        t.onWorker { }
        Thread.sleep(100)
        assertTrue(configHits.isEmpty()) // The Bearer token never went out over http.
        assertTrue(logs.any { it.contains("設定網址不是 https") })
        assertFalse(logs.any { it.contains("127.0.0.1") })
    }

    @Test fun callMarkerIsWrittenReadAndCleared() {
        val t = telemetry()
        val marker = CallMarker("c-1", "room", "1001", "agora", "agora-4.7.0", 42L)
        t.writeCallMarker(marker.encode())
        assertEquals(marker, CallMarker.decode(telemetry().readCallMarker()))
        t.writeCallMarker(null)
        assertNull(t.readCallMarker())
    }
}
