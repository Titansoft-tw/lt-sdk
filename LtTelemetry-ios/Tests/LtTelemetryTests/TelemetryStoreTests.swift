import Foundation
import Testing
@testable import LtTelemetry

final class UidCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String { lock.withLock { n += 1; return "uid-\(n)" } }
}

/// The on-disk queue: survives a restart, sends the important lane first, drops the least important first.
@Suite(.serialized) struct TelemetryStoreTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-store-\(UUID().uuidString)")
    private let uids = UidCounter()
    private let now: Int64 = 1_000_000_000_000
    private func store(maxBytes: Int64 = TelemetryStore.defaultMaxBytes, maxAgeMs: Int64 = TelemetryStore.defaultMaxAgeMs) -> TelemetryStore {
        let now = self.now, uids = self.uids
        return TelemetryStore(dir: dir, maxBytes: maxBytes, maxAgeMs: maxAgeMs, clock: { now }, newUid: { uids.next() })
    }
    private let leg = TelemetryLeg(callId: "call-1", channel: "room", user: "1001", engine: "agora")
    private func sample(_ at: Int64) -> TelemetryRecord { Telemetry.qualitySecond(leg, AudioMetrics(rttMs: 10), atEpochMs: at) }
    private func event(_ at: Int64) -> TelemetryRecord { Telemetry.sdkEvent(leg, label: "network", event: "x", reason: "net_changed", atEpochMs: at) }
    private func error(_ at: Int64) -> TelemetryRecord {
        Telemetry.appError(AppError(.api, "http_503", detail: "a=b&c\td\nline 中文"), stage: "idle", count: 1, atEpochMs: at)
    }
    private func drain(_ s: TelemetryStore) -> [[TelemetryRecord]] {
        var out: [[TelemetryRecord]] = []
        while let b = s.next() { s.complete(b, sent: true); out.append(b.records) }
        return out
    }
    private var logFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "log" }
    }

    @Test func recordsSurviveARestartWithTheirUidAndAreSentOnce() {
        store().append([error(1), event(2), sample(3)])
        let restarted = store()
        let records = drain(restarted).flatMap { $0 }
        #expect(records.map(\.atEpochMs) == [1, 2, 3])
        #expect(records.map { $0.attributes[TelemetryStore.uid] } == ["uid-1", "uid-2", "uid-3"])
        #expect(records.first?.attributes["detail"]?.contains("中文") == true)
        #expect(restarted.isEmpty)
        #expect(store().next() == nil)
        #expect(store().bytes == 0)
    }

    @Test func criticalGoesFirstThenEventsThenSamples() {
        let s = store()
        s.append([sample(1), event(2), sample(3), error(4)])
        #expect(drain(s).map { $0.map(\.atEpochMs) } == [[4], [2], [1, 3]])
        let marker = CallMarker(callId: "c", channel: "", user: "", engine: "", sdkVersion: "", startedAtMs: 0)
        #expect(TelemetryStore.Lane.of(Telemetry.abnormalExit(marker, exitReason: "crash", atEpochMs: 1)) == .critical)
    }

    @Test func aBatchIsOneSegmentOfAtMost200Records() {
        let s = store()
        s.append((1...450).map { sample(Int64($0)) })
        #expect(drain(s).map(\.count) == [200, 200, 50])
    }

    @Test func recordsAddedWhileABatchIsOutGoToTheNextBatch() throws {
        let s = store()
        s.append([sample(1)])
        let out = try #require(s.next())
        s.append([sample(2)])
        s.release(out)
        #expect(drain(s).map { $0.map(\.atEpochMs) } == [[1], [2]])
    }

    @Test func overTheCapSamplesAreDroppedBeforeEventsAndErrors() {
        let one = Int64((TelemetryStore.encode(TelemetryRecord(body: sample(0).body, atEpochMs: 0,
            attributes: sample(0).attributes.merging([TelemetryStore.uid: "uid-1"]) { a, _ in a }))! + "\n").utf8.count)
        let s = store(maxBytes: one * 5)
        s.append([error(1)])
        s.append([event(2)])
        for i in 0..<6 { s.append([sample(10 + Int64(i))]); if let b = s.next() { s.release(b) } }
        let left = s.pending()
        #expect(left.contains { $0.body == Telemetry.appErrorBody })
        #expect(left.contains { $0.body == Telemetry.sdkEvent })
        #expect(s.bytes <= one * 6)
        #expect((s.takeDropped()[.overflow] ?? 0) >= 1)
        #expect(s.takeDropped().isEmpty)
    }

    @Test func oldSegmentsExpireAndDropCountsSurviveARestart() throws {
        let s = store(maxAgeMs: 1_000)
        s.append([sample(1), sample(2)])
        let old = Date(timeIntervalSince1970: Double(now - 5_000) / 1000)
        for file in logFiles { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }
        #expect(s.next() == nil)
        #expect(store().takeDropped() == [.expired: 2])
        #expect(store().takeDropped().isEmpty)
    }

    @Test func corruptLinesAreSkippedAndCounted() throws {
        store().append([event(1)])
        let file = try #require(logFiles.first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("garbage\n{\"v\":2}\n".utf8)); try handle.close()
        let s = store()
        #expect(drain(s).flatMap { $0 }.map(\.atEpochMs) == [1])
        #expect(s.takeDropped() == [.corrupt: 2])
    }

    @Test func aRejectedBatchIsDeletedAndCounted() throws {
        let s = store()
        s.append([event(1), event(2)])
        s.complete(try #require(s.next()), sent: false)
        #expect(s.isEmpty)
        #expect(s.takeDropped() == [.rejected: 2])
    }
}

extension TelemetryStore.Batch: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.seq == b.seq }
}
