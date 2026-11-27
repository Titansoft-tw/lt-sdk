package com.tswork.lt.telemetry

import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Every record is written here before it is sent (persist first, like Sentry's envelope cache and Firebase
 * Analytics' local database), so a crash, an OOM kill or a swipe-away loses nothing that [append] returned for:
 * once the bytes are written they sit in the OS page cache and outlive the process (only a power loss could lose
 * them, so there is no fsync).
 *
 * Layout: append-only segment files `<seq>-<lane>.log` in [dir], one record per line. [append] writes to the open
 * segment of the record's [Lane]; [next] seals the oldest segment of the most important lane and hands it out as
 * one batch; [complete] deletes it. Over [maxBytes] the oldest segment of the least important lane goes first
 * ([Lane.BULK] → [Lane.EVENT] → [Lane.CRITICAL]); segments older than [maxAgeMs] are dropped. What is dropped
 * is counted by reason ([takeDropped]) and survives the process too.
 *
 * Thread-safe. Disk errors never throw: a record that cannot be written is counted as dropped.
 */
internal class TelemetryStore(
    private val dir: File,
    private val maxBytes: Long = DEFAULT_MAX_BYTES,
    private val maxAgeMs: Long = DEFAULT_MAX_AGE_MS,
    private val clock: () -> Long = System::currentTimeMillis,
    private val newUid: () -> String = { UUID.randomUUID().toString() },
) {
    /** Send order and eviction order: CRITICAL is sent first and dropped last. */
    enum class Lane(val code: String) {
        CRITICAL("c"), EVENT("e"), BULK("b");
        companion object {
            /** app_error and abnormal_exit are CRITICAL, quality_second is BULK, everything else is EVENT. */
            fun of(record: TelemetryRecord) = when {
                record.body == Telemetry.APP_ERROR || record.attributes["reason"] == "abnormal_exit" -> CRITICAL
                record.body == Telemetry.QUALITY_SECOND -> BULK
                else -> EVENT
            }
            fun ofCode(code: String) = entries.firstOrNull { it.code == code }
        }
    }

    /** Why records were dropped; also the attribute suffix of the `telemetry/dropped` report (`dropped_<code>`). */
    enum class Drop(val code: String) { OVERFLOW("overflow"), EXPIRED("expired"), REJECTED("rejected"), CORRUPT("corrupt") }

    /** One sealed segment handed to the uploader; pass it back to [complete]. */
    class Batch internal constructor(internal val segment: Segment, val records: List<TelemetryRecord>)

    internal class Segment(val seq: Long, val lane: Lane, val file: File) {
        var records = 0
        var bytes = 0L
    }

    private val lock = Any()
    private val segments = sortedMapOf<Long, Segment>()
    private val open = mutableMapOf<Lane, Segment>()
    private val inFlight = mutableSetOf<Long>()
    private var nextSeq = 1L
    private var totalBytes = 0L
    private val droppedFile = File(dir, "dropped.txt")
    private val dropped = mutableMapOf<Drop, Int>()

    init {
        synchronized(lock) {
            runCatching { dir.mkdirs() }
            dir.listFiles()?.forEach { file ->
                val match = SEGMENT_NAME.matchEntire(file.name) ?: return@forEach
                val lane = Lane.ofCode(match.groupValues[2]) ?: return@forEach
                val seq = match.groupValues[1].toLong()
                // Segments left by an earlier process are sealed: new records go to new segments.
                segments[seq] = Segment(seq, lane, file).also { it.records = -1; it.bytes = file.length() }
                nextSeq = maxOf(nextSeq, seq + 1)
            }
            totalBytes = segments.values.sumOf { it.bytes }
            readDropped()
        }
    }

    /** Writes [records] to disk before returning. Each gets a `log.record.uid` (kept on retries, so the platform can de-duplicate). */
    fun append(records: List<TelemetryRecord>) {
        if (records.isEmpty()) return
        synchronized(lock) {
            for ((lane, group) in records.groupBy(Lane::of)) {
                for (record in group) {
                    val withUid = if (record.attributes.containsKey(UID)) record else record.copy(attributes = record.attributes + (UID to newUid()))
                    val line = (encode(withUid) + "\n").toByteArray()
                    val segment = openSegment(lane, line.size)
                    if (segment == null) { count(Drop.OVERFLOW, 1); continue }
                    val written = runCatching { FileOutputStream(segment.file, true).use { it.write(line) } }.isSuccess
                    if (!written) { count(Drop.OVERFLOW, 1); continue }
                    segment.records++
                    segment.bytes += line.size
                    totalBytes += line.size
                }
            }
            enforceCap()
        }
    }

    /**
     * The next batch to send, or null when nothing is waiting: the oldest segment of the most important lane, sealed
     * (later records go to a new segment). Expired segments are dropped first. A batch stays out of eviction until [complete].
     */
    fun next(): Batch? = synchronized(lock) {
        expire()
        var batch: Batch? = null
        while (batch == null) {
            val segment = Lane.entries.firstNotNullOfOrNull { lane ->
                segments.values.firstOrNull { it.lane == lane && it.seq !in inFlight && it.bytes > 0 }
            } ?: break
            open.remove(segment.lane, segment)
            val lines = runCatching { segment.file.readLines() }.getOrDefault(emptyList()).filter { it.isNotBlank() }
            val records = lines.mapNotNull(::decode)
            if (records.size < lines.size) count(Drop.CORRUPT, lines.size - records.size)
            if (records.isEmpty()) { delete(segment); continue }
            inFlight += segment.seq
            batch = Batch(segment, records)
        }
        batch
    }

    /** [sent] = the collector took it; false = it rejected it for good (bad token, bad payload). Either way it is deleted. */
    fun complete(batch: Batch, sent: Boolean) = synchronized(lock) {
        inFlight -= batch.segment.seq
        if (!sent) count(Drop.REJECTED, batch.records.size)
        delete(batch.segment)
    }

    /** The batch could not be delivered now; it stays queued (and may be evicted again). */
    fun release(batch: Batch) = synchronized(lock) { inFlight -= batch.segment.seq; Unit }

    /** Counts of dropped records since the last call, and resets them. */
    fun takeDropped(): Map<Drop, Int> = synchronized(lock) {
        val result = dropped.filterValues { it > 0 }
        if (result.isNotEmpty()) { dropped.clear(); writeDropped() }
        result
    }

    val isEmpty: Boolean get() = synchronized(lock) { segments.values.none { it.bytes > 0 } }
    /** Bytes on disk (tests, diagnostics). */
    val bytes: Long get() = synchronized(lock) { totalBytes }
    /** Every queued record, oldest first per lane in send order (tests). */
    internal fun pending(): List<TelemetryRecord> = synchronized(lock) {
        Lane.entries.flatMap { lane -> segments.values.filter { it.lane == lane } }
            .flatMap { s -> runCatching { s.file.readLines() }.getOrDefault(emptyList()).mapNotNull(::decode) }
    }

    private fun openSegment(lane: Lane, lineBytes: Int): Segment? {
        val current = open[lane]
        if (current != null && segments.containsKey(current.seq) && current.records in 0 until SEGMENT_RECORDS &&
            current.bytes + lineBytes <= SEGMENT_BYTES) return current
        if (lineBytes > maxBytes) return null
        val seq = nextSeq++
        val segment = Segment(seq, lane, File(dir, "%012d-%s.log".format(seq, lane.code)))
        segments[seq] = segment
        open[lane] = segment
        return segment
    }

    private fun enforceCap() {
        while (totalBytes > maxBytes) {
            val victim = Lane.entries.reversed().firstNotNullOfOrNull { lane ->
                segments.values.firstOrNull { it.lane == lane && it.seq !in inFlight }
            } ?: return
            count(Drop.OVERFLOW, recordsIn(victim))
            delete(victim)
        }
    }

    private fun expire() {
        val cutoff = clock() - maxAgeMs
        for (segment in segments.values.toList()) {
            if (segment.seq in inFlight) continue
            val modified = segment.file.lastModified()
            if (modified in 1 until cutoff) { count(Drop.EXPIRED, recordsIn(segment)); delete(segment) }
        }
    }

    private fun recordsIn(segment: Segment) = if (segment.records >= 0) segment.records
        else runCatching { segment.file.readLines().count { it.isNotBlank() } }.getOrDefault(0)

    private fun delete(segment: Segment) {
        segments.remove(segment.seq)
        open.remove(segment.lane, segment)
        totalBytes -= segment.bytes
        runCatching { segment.file.delete() }
    }

    private fun count(reason: Drop, n: Int) {
        if (n <= 0) return
        dropped[reason] = (dropped[reason] ?: 0) + n
        writeDropped()
    }

    private fun readDropped() = runCatching {
        droppedFile.takeIf { it.exists() }?.readLines()?.forEach { line ->
            val (code, n) = line.split("=", limit = 2).takeIf { it.size == 2 } ?: return@forEach
            val reason = Drop.entries.firstOrNull { it.code == code } ?: return@forEach
            n.toIntOrNull()?.let { dropped[reason] = it }
        }
    }

    private fun writeDropped() = runCatching {
        val text = dropped.filterValues { it > 0 }.entries.joinToString("\n") { "${it.key.code}=${it.value}" }
        if (text.isEmpty()) droppedFile.delete() else writeAtomically(droppedFile, text)
    }

    companion object {
        /** OpenTelemetry semantic convention: a unique id per log record, for de-duplication after a retry. */
        const val UID = "log.record.uid"
        const val DEFAULT_MAX_BYTES = 5L * 1024 * 1024
        const val DEFAULT_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
        /** One segment = at most one POST. */
        const val SEGMENT_RECORDS = 200
        const val SEGMENT_BYTES = 256L * 1024
        private val SEGMENT_NAME = Regex("(\\d{12})-([a-z])\\.log")

        // One line per record, tab-separated, every field URL-encoded (tabs, newlines and '=' inside values are safe).
        // Same "v1" format as the earlier telemetry-durable.txt, which is imported at startup.
        internal fun encode(r: TelemetryRecord) = (listOf("v1", r.severity, r.body, r.atEpochMs.toString()).map(::enc) +
            r.attributes.map { (k, v) -> enc(k) + "=" + enc(v) }).joinToString("\t")
        internal fun decode(line: String): TelemetryRecord? = runCatching {
            val parts = line.split("\t")
            if (parts.size < 4 || dec(parts[0]) != "v1") return null
            val attributes = parts.drop(4).associate { field ->
                val (k, v) = field.split("=", limit = 2).also { require(it.size == 2) }
                dec(k) to dec(v)
            }
            TelemetryRecord(dec(parts[2]), dec(parts[3]).toLong(), attributes, dec(parts[1]))
        }.getOrNull()

        internal fun writeAtomically(file: File, text: String) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        }
    }
}
