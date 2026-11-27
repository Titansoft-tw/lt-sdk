import Foundation

/// Every record is written here before it is sent (persist first, like Sentry's envelope cache and Firebase Analytics'
/// local database), so a crash, a jetsam kill or a swipe-away loses nothing `append` returned for: once written, the
/// bytes sit in the OS page cache and outlive the process (only a power loss could lose them, so there is no fsync).
///
/// Layout: append-only segment files `<seq>-<lane>.log` in `dir`, one JSON record per line. `append` writes to the open
/// segment of the record's `Lane`; `next` seals the oldest segment of the most important lane and hands it out as one
/// batch; `complete` deletes it. Over `maxBytes` the oldest segment of the least important lane goes first
/// (bulk → event → critical); segments older than `maxAgeMs` are dropped. What is dropped is counted by reason
/// (`takeDropped`) and survives the process too. Same rules as Android's TelemetryStore.kt.
///
/// Thread-safe (a lock): the app's main actor appends, the uploader reads. Disk errors never throw: a record that
/// cannot be written is counted as dropped.
public final class TelemetryStore: @unchecked Sendable {
    /// Send order and eviction order: critical is sent first and dropped last.
    public enum Lane: String, CaseIterable, Sendable {
        case critical = "c", event = "e", bulk = "b"
        /// app_error and abnormal_exit are critical, quality_second is bulk, everything else is event.
        public static func of(_ record: TelemetryRecord) -> Lane {
            if record.body == Telemetry.appErrorBody || record.attributes["reason"] == "abnormal_exit" { return .critical }
            return record.body == Telemetry.qualitySecond ? .bulk : .event
        }
    }

    /// Why records were dropped; also the attribute suffix of the `telemetry/dropped` report (`dropped_<rawValue>`).
    public enum Drop: String, CaseIterable, Sendable { case overflow, expired, rejected, corrupt }

    /// One sealed segment handed to the uploader; pass it back to `complete` or `release`.
    public struct Batch: Sendable {
        let seq: Int64
        public let records: [TelemetryRecord]
    }

    /// OpenTelemetry semantic convention: a unique id per log record, for de-duplication after a retry.
    public static let uid = "log.record.uid"
    public static let defaultMaxBytes: Int64 = 5 * 1024 * 1024
    public static let defaultMaxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// One segment = at most one POST.
    public static let segmentRecords = 200
    public static let segmentBytes: Int64 = 256 * 1024

    private final class Segment {
        let seq: Int64, lane: Lane, url: URL
        var records: Int   // -1 = unknown (left by an earlier process)
        var bytes: Int64
        init(seq: Int64, lane: Lane, url: URL, records: Int, bytes: Int64) {
            self.seq = seq; self.lane = lane; self.url = url; self.records = records; self.bytes = bytes
        }
    }

    private let dir: URL
    private let maxBytes: Int64
    private let maxAgeMs: Int64
    private let clock: @Sendable () -> Int64
    private let newUid: @Sendable () -> String
    private let lock = NSLock()
    private var segments: [Int64: Segment] = [:]
    private var open: [Lane: Segment] = [:]
    private var inFlight = Set<Int64>()
    private var nextSeq: Int64 = 1
    private var totalBytes: Int64 = 0
    private var dropped: [Drop: Int] = [:]
    private let droppedUrl: URL
    private let files = FileManager.default

    public init(dir: URL, maxBytes: Int64 = TelemetryStore.defaultMaxBytes, maxAgeMs: Int64 = TelemetryStore.defaultMaxAgeMs,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                newUid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.dir = dir; self.maxBytes = maxBytes; self.maxAgeMs = maxAgeMs; self.clock = clock; self.newUid = newUid
        droppedUrl = dir.appendingPathComponent("dropped.txt")
        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasSuffix(".log") else { continue }
            let parts = name.dropLast(4).split(separator: "-")
            guard parts.count == 2, parts[0].count == 12, let seq = Int64(parts[0]), let lane = Lane(rawValue: String(parts[1])) else { continue }
            // Segments left by an earlier process are sealed: new records go to new segments.
            segments[seq] = Segment(seq: seq, lane: lane, url: url, records: -1, bytes: Self.size(url))
            nextSeq = max(nextSeq, seq + 1)
        }
        totalBytes = segments.values.reduce(0) { $0 + $1.bytes }
        readDropped()
    }

    /// Writes `records` to disk before returning. Each gets a `log.record.uid` (kept on retries, so the platform can de-duplicate).
    public func append(_ records: [TelemetryRecord]) {
        guard !records.isEmpty else { return }
        lock.withLock {
            for record in records {
                let withUid = record.attributes[Self.uid] != nil ? record
                    : TelemetryRecord(body: record.body, atEpochMs: record.atEpochMs,
                                      attributes: record.attributes.merging([Self.uid: newUid()]) { a, _ in a }, severity: record.severity)
                guard let line = Self.encode(withUid).map({ Data(($0 + "\n").utf8) }) else { count(.overflow, 1); continue }
                guard let segment = openSegment(Lane.of(record), Int64(line.count)), write(line, to: segment.url) else {
                    count(.overflow, 1); continue
                }
                segment.records += 1
                segment.bytes += Int64(line.count)
                totalBytes += Int64(line.count)
            }
            enforceCap()
        }
    }

    /// The next batch to send, or nil when nothing is waiting: the oldest segment of the most important lane, sealed
    /// (later records go to a new segment). Expired segments are dropped first. A batch stays out of eviction until
    /// `complete` / `release`.
    public func next() -> Batch? {
        lock.withLock {
            expire()
            while true {
                let candidates = segments.values.filter { !inFlight.contains($0.seq) && $0.bytes > 0 }
                guard let segment = Lane.allCases.lazy.compactMap({ lane in
                    candidates.filter { $0.lane == lane }.min { $0.seq < $1.seq }
                }).first else { return nil }
                if open[segment.lane] === segment { open[segment.lane] = nil }
                let lines = Self.lines(segment.url)
                let records = lines.compactMap(Self.decode)
                if records.count < lines.count { count(.corrupt, lines.count - records.count) }
                if records.isEmpty { delete(segment); continue }
                inFlight.insert(segment.seq)
                return Batch(seq: segment.seq, records: records)
            }
        }
    }

    /// `sent` = the collector took it; false = it rejected it for good (bad token, bad payload). Either way it is deleted.
    public func complete(_ batch: Batch, sent: Bool) {
        lock.withLock {
            inFlight.remove(batch.seq)
            if !sent { count(.rejected, batch.records.count) }
            if let segment = segments[batch.seq] { delete(segment) }
        }
    }

    /// The batch could not be delivered now; it stays queued (and may be evicted again).
    public func release(_ batch: Batch) { lock.withLock { _ = inFlight.remove(batch.seq) } }

    /// Counts of dropped records since the last call, and resets them.
    public func takeDropped() -> [Drop: Int] {
        lock.withLock {
            let result = dropped.filter { $0.value > 0 }
            if !result.isEmpty { dropped = [:]; writeDropped() }
            return result
        }
    }

    public var isEmpty: Bool { lock.withLock { !segments.values.contains { $0.bytes > 0 } } }
    /// Bytes on disk (tests, diagnostics).
    public var bytes: Int64 { lock.withLock { totalBytes } }
    /// Every queued record, per lane in send order, oldest first (tests).
    func pending() -> [TelemetryRecord] {
        lock.withLock {
            Lane.allCases.flatMap { lane in
                segments.values.filter { $0.lane == lane }.sorted { $0.seq < $1.seq }.flatMap { Self.lines($0.url).compactMap(Self.decode) }
            }
        }
    }

    // MARK: - Under the lock

    private func openSegment(_ lane: Lane, _ lineBytes: Int64) -> Segment? {
        if let current = open[lane], segments[current.seq] != nil, (0..<Self.segmentRecords).contains(current.records),
           current.bytes + lineBytes <= Self.segmentBytes { return current }
        if lineBytes > maxBytes { return nil }
        let seq = nextSeq
        nextSeq += 1
        let segment = Segment(seq: seq, lane: lane, url: dir.appendingPathComponent(String(format: "%012lld-%@.log", seq, lane.rawValue)),
                              records: 0, bytes: 0)
        segments[seq] = segment
        open[lane] = segment
        return segment
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        if !files.fileExists(atPath: url.path) { return files.createFile(atPath: url.path, contents: data) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data); return true } catch { return false }
    }

    private func enforceCap() {
        while totalBytes > maxBytes {
            guard let victim = Lane.allCases.reversed().lazy.compactMap({ lane in
                self.segments.values.filter { $0.lane == lane && !self.inFlight.contains($0.seq) }.min { $0.seq < $1.seq }
            }).first else { return }
            count(.overflow, recordsIn(victim))
            delete(victim)
        }
    }

    private func expire() {
        let cutoff = clock() - maxAgeMs
        for segment in Array(segments.values) where !inFlight.contains(segment.seq) {
            guard let modified = (try? files.attributesOfItem(atPath: segment.url.path))?[.modificationDate] as? Date else { continue }
            if Int64(modified.timeIntervalSince1970 * 1000) < cutoff { count(.expired, recordsIn(segment)); delete(segment) }
        }
    }

    private func recordsIn(_ segment: Segment) -> Int { segment.records >= 0 ? segment.records : Self.lines(segment.url).count }

    private func delete(_ segment: Segment) {
        segments[segment.seq] = nil
        if open[segment.lane] === segment { open[segment.lane] = nil }
        totalBytes -= segment.bytes
        try? files.removeItem(at: segment.url)
    }

    private func count(_ reason: Drop, _ n: Int) {
        guard n > 0 else { return }
        dropped[reason, default: 0] += n
        writeDropped()
    }

    private func readDropped() {
        guard let text = try? String(contentsOf: droppedUrl, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let reason = Drop(rawValue: String(kv[0])), let n = Int(kv[1]) { dropped[reason] = n }
        }
    }

    private func writeDropped() {
        let text = dropped.filter { $0.value > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: "\n")
        if text.isEmpty { try? files.removeItem(at: droppedUrl) } else { try? text.write(to: droppedUrl, atomically: true, encoding: .utf8) }
    }

    // MARK: - Encoding

    private struct Stored: Codable {
        let v: Int, body: String, at: Int64, severity: String, attributes: [String: String]
    }

    static func encode(_ r: TelemetryRecord) -> String? {
        (try? JSONEncoder().encode(Stored(v: 1, body: r.body, at: r.atEpochMs, severity: r.severity, attributes: r.attributes)))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode(_ line: Substring) -> TelemetryRecord? { decode(String(line)) }
    static func decode(_ line: String) -> TelemetryRecord? {
        guard let s = try? JSONDecoder().decode(Stored.self, from: Data(line.utf8)), s.v == 1 else { return nil }
        return TelemetryRecord(body: s.body, atEpochMs: s.at, attributes: s.attributes, severity: s.severity)
    }

    private static func lines(_ url: URL) -> [Substring] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
