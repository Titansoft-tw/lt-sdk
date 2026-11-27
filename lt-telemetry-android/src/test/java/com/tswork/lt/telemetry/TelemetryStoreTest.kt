package com.tswork.lt.telemetry

import com.tswork.lt.telemetry.TelemetryStore.Drop
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The on-disk queue: survives a restart, sends the important lane first, drops the least important first. */
class TelemetryStoreTest {
    private val dir: File = Files.createTempDirectory("lt-store").toFile()
    private var now = 1_000_000_000_000L
    private var uids = 0
    private fun store(maxBytes: Long = TelemetryStore.DEFAULT_MAX_BYTES, maxAgeMs: Long = TelemetryStore.DEFAULT_MAX_AGE_MS) =
        TelemetryStore(dir, maxBytes, maxAgeMs, clock = { now }, newUid = { "uid-${++uids}" })

    @After fun clean() { dir.deleteRecursively() }

    private val leg = TelemetryLeg(callId = "call-1", channel = "room", user = "1001", engine = "agora")
    private fun sample(at: Long) = Telemetry.qualitySecond(leg, AudioMetrics(rttMs = 10.0), at)
    private fun event(at: Long) = Telemetry.sdkEvent(leg, "network", "x", "net_changed", at)
    private fun error(at: Long) = Telemetry.appError(AppError(ErrorDomain.API, "http_503", detail = "a=b&c\td\nline 中文"), "idle", 1, at)

    private fun drain(store: TelemetryStore): List<List<TelemetryRecord>> = generateSequence {
        store.next()?.also { store.complete(it, sent = true) }?.records
    }.toList()

    @Test fun recordsSurviveARestartWithTheirUidAndAreSentOnce() {
        val first = store()
        first.append(listOf(error(1), event(2), sample(3)))
        // A new process: nothing sent yet, everything still on disk, the uid assigned before the restart kept.
        val restarted = store()
        val batches = drain(restarted)
        val records = batches.flatten()
        assertEquals(listOf(1L, 2L, 3L), records.map { it.atEpochMs })
        assertEquals(listOf("uid-1", "uid-2", "uid-3"), records.map { it.attributes[TelemetryStore.UID] })
        assertEquals("a=b&c\td\nline 中文", records.first().attributes["detail"])
        assertTrue(restarted.isEmpty)
        assertNull(store().next()) // Not again.
        assertEquals(0L, store().bytes)
    }

    @Test fun criticalGoesFirstThenEventsThenSamples() {
        val s = store()
        s.append(listOf(sample(1), event(2), sample(3), error(4)))
        val batches = drain(s)
        assertEquals(listOf(listOf(4L), listOf(2L), listOf(1L, 3L)), batches.map { b -> b.map { it.atEpochMs } })
        assertEquals(TelemetryStore.Lane.CRITICAL, TelemetryStore.Lane.of(Telemetry.abnormalExit(CallMarker("c", "", "", "", "", 0), "crash", 1)))
    }

    @Test fun aBatchIsOneSegmentOfAtMost200Records() {
        val s = store()
        s.append((1..450).map { sample(it.toLong()) })
        assertEquals(listOf(200, 200, 50), drain(s).map { it.size })
    }

    @Test fun recordsAddedWhileABatchIsOutGoToTheNextBatch() {
        val s = store()
        s.append(listOf(sample(1)))
        val out = s.next()!!
        s.append(listOf(sample(2)))
        s.release(out) // Offline: kept.
        assertEquals(listOf(listOf(1L), listOf(2L)), drain(s).map { b -> b.map { it.atEpochMs } })
    }

    @Test fun overTheCapSamplesAreDroppedBeforeEventsAndErrors() {
        val one = (TelemetryStore.encode(sample(0).copy(attributes = sample(0).attributes + (TelemetryStore.UID to "uid-1"))) + "\n").length
        val s = store(maxBytes = one * 5L)
        s.append(listOf(error(1)))
        s.append(listOf(event(2)))
        // Samples come in several segments (one append each after a send) so the oldest segment can go.
        repeat(6) { i -> s.append(listOf(sample(10L + i))); s.next()?.let(s::release) }
        val left = s.pending()
        assertTrue(left.any { it.body == Telemetry.APP_ERROR })
        assertTrue(left.any { it.body == Telemetry.SDK_EVENT })
        assertTrue(s.bytes <= one * 5L + one) // Within the cap, give or take one line of size difference.
        val dropped = s.takeDropped()
        assertTrue((dropped[Drop.OVERFLOW] ?: 0) >= 1)
        assertTrue(s.takeDropped().isEmpty()) // Reset once taken.
    }

    @Test fun oldSegmentsExpireAndDropCountsSurviveARestart() {
        val s = store(maxAgeMs = 1_000)
        s.append(listOf(sample(1), sample(2)))
        dir.listFiles()!!.filter { it.name.endsWith(".log") }.forEach { it.setLastModified(now - 5_000) }
        assertNull(s.next())
        assertEquals(mapOf(Drop.EXPIRED to 2), store().takeDropped()) // Read back by a new process.
        assertTrue(store().takeDropped().isEmpty())
    }

    @Test fun corruptLinesAreSkippedAndCounted() {
        store().append(listOf(event(1)))
        val file = dir.listFiles()!!.single { it.name.endsWith(".log") }
        file.appendText("garbage\n\tmore\n")
        val s = store()
        assertEquals(listOf(1L), drain(s).flatten().map { it.atEpochMs })
        assertEquals(mapOf(Drop.CORRUPT to 2), s.takeDropped())
    }

    @Test fun aRejectedBatchIsDeletedAndCounted() {
        val s = store()
        s.append(listOf(event(1), event(2)))
        s.complete(s.next()!!, sent = false)
        assertTrue(s.isEmpty)
        assertEquals(mapOf(Drop.REJECTED to 2), s.takeDropped())
    }

    @Test fun unknownFilesInTheDirectoryAreLeftAlone() {
        File(dir, "notes.txt").writeText("x")
        val s = store()
        assertTrue(s.isEmpty)
        assertFalse(s.next() != null)
        assertTrue(File(dir, "notes.txt").exists())
    }
}
