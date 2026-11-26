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

/** The transport against a local HTTP server: delivery, headers, retry, permanent rejection, durable queue. */
class LtTelemetryTest {
    private class Hit(val body: String, val auth: String?)
    private val hits = CopyOnWriteArrayList<Hit>()
    /** Status codes to answer with, in order; 200 once they run out. */
    private val statuses = CopyOnWriteArrayList<Int>()
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
                    val body = ByteArray(header("Content-Length")?.toInt() ?: 0).also { var n = 0; while (n < it.size) n += input.read(it, n, it.size - n) }
                    hits += Hit(body.decodeToString(), header("Authorization"))
                    val status = if (statuses.isEmpty()) 200 else statuses.removeAt(0)
                    s.getOutputStream().write("HTTP/1.1 $status X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
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

    private fun telemetry(url: String? = this.url, requireHttps: Boolean = false, log: (String) -> Unit = {}) = LtTelemetry(
        TelemetryConfig(url, headers = { mapOf("Authorization" to "Bearer t0k") }, requireHttps = requireHttps,
            serviceName = "unit-test", device = device, storageDir = dir, log = log), retryMs = 50)

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

    @Test fun durableRecordsSurviveARestart() {
        val error = Telemetry.appError(AppError(ErrorDomain.API, "http_503"), "idle", 1, 1L)
        val down = telemetry(url = "http://127.0.0.1:1/v1/logs") // Nothing listens: status 0.
        down.send(listOf(error))
        eventually("durable file") { File(dir, "telemetry-durable.txt").exists() }
        telemetry() // Next launch, collector reachable.
        eventually("sent at launch") { hits.any { it.body.contains("http_503") } }
        eventually("file removed") { !File(dir, "telemetry-durable.txt").exists() }
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

    @Test fun callMarkerIsWrittenReadAndCleared() {
        val t = telemetry()
        val marker = CallMarker("c-1", "room", "1001", "agora", "agora-4.7.0", 42L)
        t.writeCallMarker(marker.encode())
        assertEquals(marker, CallMarker.decode(telemetry().readCallMarker()))
        t.writeCallMarker(null)
        assertNull(t.readCallMarker())
    }
}
