import Foundation
import Testing
@testable import LtTelemetry

/// Answers every request from `StubCollector` instead of the network.
final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = StubCollector.shared.answer(request)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class StubCollector: @unchecked Sendable {
    static let shared = StubCollector()
    struct Hit { let body: String; let auth: String?; var at = Date() }
    private let lock = NSLock()
    private var _hits: [Hit] = []
    /// Statuses to answer with, in order (0 = no answer); 200 once they run out.
    private var statuses: [Int] = []
    /// Retry-After values sent with the statuses above, in the same order (nil = none).
    private var retryAfters: [String?] = []
    /// GET <base>/config/telemetry.json: the file served (nil = 404) and the If-None-Match each request sent.
    private var _configBody: String?
    private var _configEtag = "\"v1\""
    private var _configHits: [String?] = []
    var hits: [Hit] { lock.withLock { _hits } }
    var configHits: [String?] { lock.withLock { _configHits } }
    func serveConfig(_ body: String?, etag: String = "\"v1\"") { lock.withLock { _configBody = body; _configEtag = etag } }
    func reset(_ statuses: [Int] = [], retryAfters: [String?] = []) {
        lock.withLock { _hits = []; self.statuses = statuses; self.retryAfters = retryAfters; _configBody = nil; _configHits = [] }
    }
    func answer(_ request: URLRequest) -> (Int, [String: String], Data) {
        if request.url?.path == "/config/telemetry.json" {
            return lock.withLock {
                let sent = request.value(forHTTPHeaderField: "If-None-Match")
                _configHits.append(sent)
                guard let body = _configBody else { return (404, [:], Data()) }
                if sent == _configEtag { return (304, ["ETag": _configEtag], Data()) }
                return (200, ["ETag": _configEtag], Data(body.utf8))
            }
        }
        let status = receive(request)
        let retryAfter = lock.withLock { retryAfters.isEmpty ? nil : retryAfters.removeFirst() }
        return (status, retryAfter.map { ["Retry-After": $0] } ?? [:], Data())
    }
    func receive(_ request: URLRequest) -> Int {
        // URLProtocol gets the body as a stream.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { body.append(buffer, count: n) }
        }
        // down.test plays a collector that cannot be reached; it is not recorded.
        if request.url?.host == "down.test" { return 0 }
        return lock.withLock {
            _hits.append(Hit(body: String(decoding: body, as: UTF8.self), auth: request.value(forHTTPHeaderField: "Authorization")))
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    var all: [String] { lock.withLock { _all } }
    func add(_ line: String) { lock.withLock { _all.append(line) } }
}

/// The transport against a stub collector: delivery, headers, retry, permanent rejection, durable queue, call marker.
@MainActor @Suite(.serialized) struct LtTelemetryTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-telemetry-\(UUID().uuidString)")
    private let device = StaticDevice(platform: "ios", osVersion: "18.1", appVersion: "1.0", model: "Apple iPhone14,2", brand: "Apple")
    private var collector: StubCollector { .shared }

    private func telemetry(url: String? = "http://collector.test/v1/logs", requireHttps: Bool = false, log: Lines = Lines(),
                           retryMs: Int64 = 50, startupWaitMs: Int64 = 0, onBacklog: @escaping @Sendable () -> Void = {}) -> LtTelemetry {
        LtTelemetry(TelemetryConfig(logsUrl: url, headers: { ["Authorization": "Bearer t0k"] }, requireHttps: requireHttps,
                                    serviceName: "unit-test", device: device, storageDir: dir, log: { log.add($0) },
                                    startupCrashWaitMs: startupWaitMs, onBacklog: onBacklog),
                    retryMs: retryMs, maxRetryMs: retryMs * 4, jitter: { 0.5 }, protocolClasses: [StubProtocol.self])
    }
    private func uids(_ body: String) -> [String] {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logs = (((json["resourceLogs"] as? [[String: Any]])?.first?["scopeLogs"] as? [[String: Any]])?.first?["logRecords"]) as? [[String: Any]]
        else { return [] }
        return logs.flatMap { ($0["attributes"] as? [[String: Any]] ?? []).filter { $0["key"] as? String == TelemetryStore.uid }
            .compactMap { ($0["value"] as? [String: Any])?["stringValue"] as? String } }
    }
    private var queueFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(LtTelemetry.queueDir).path)) ?? []).filter { $0.hasSuffix(".log") }
    }

    private func eventually(_ what: String, _ check: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !check() {
            if Date() > until { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func event(_ reason: String) -> TelemetryRecord {
        Telemetry.appEvent(label: "app_state", event: "app \(reason)", reason: reason, atEpochMs: 1)
    }

    @Test func deliversWithHeadersServiceNameAndDeviceFields() async throws {
        collector.reset()
        let log = Lines()
        let t = telemetry(log: log)
        t.send([event("background")])
        try await eventually("one post") { collector.hits.count == 1 }
        let hit = try #require(collector.hits.first)
        #expect(hit.auth == "Bearer t0k")
        #expect(hit.body.contains("\"unit-test\"") && hit.body.contains("Apple iPhone14,2"))
        try await eventually("log line") { !log.all.isEmpty }
        #expect(!log.all.contains { $0.contains("collector.test") || $0.contains("t0k") })
    }

    @Test func aServerErrorIsRetriedInOrderAndARejectionIsDropped() async throws {
        collector.reset([503])
        let t = telemetry()
        t.send([event("a")])
        try await eventually("retry") { collector.hits.count == 2 }
        #expect(collector.hits[1].body.contains("\"a\""))
        t.send([event("b")])
        try await eventually("third post") { collector.hits.count == 3 }
        #expect(collector.hits[2].body.contains("\"b\"") && !collector.hits[2].body.contains("\"a\""))
        collector.reset([400])
        t.send([event("c")])
        try await eventually("rejected post") { collector.hits.count == 1 }
        try await Task.sleep(for: .milliseconds(200)) // Longer than the retry delay: a 400 is not sent again.
        #expect(collector.hits.count == 1)
    }

    @Test func everyRecordSurvivesARestartAndErrorsGoFirst() async throws {
        collector.reset()
        let sample = Telemetry.qualitySecond(TelemetryLeg(callId: "c-1", channel: "room", user: "1001", engine: "agora"),
                                             AudioMetrics(rttMs: 10), atEpochMs: 1)
        let error = Telemetry.appError(AppError(.api, "http_503"), stage: "idle", count: 1, atEpochMs: 2)
        let down = telemetry(url: "http://down.test/v1/logs", retryMs: 60_000)
        down.send([sample, event("background")])
        down.send([error])
        _ = await down.drain(timeoutMs: 2_000) // The first attempt failed; everything is on disk.
        #expect(!(down.queue?.isEmpty ?? true))
        _ = telemetry() // Next launch (the process died), collector reachable.
        try await eventually("all sent at launch") { collector.hits.count == 3 }
        #expect(collector.hits[0].body.contains("http_503")) // app_error first.
        #expect(collector.hits[1].body.contains("\"background\""))
        #expect(collector.hits[2].body.contains("quality_second"))
        #expect(collector.hits.allSatisfy { $0.body.contains("observedTimeUnixNano") })
        try await eventually("queue empty") { queueFiles.isEmpty }
    }

    @Test func theLegacyDurableFileIsImportedOnce() async throws {
        collector.reset()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"[{"body":"app_error","at":5,"severity":"FATAL","attributes":{"error_code":"exit_low_memory"}}]"#
        try legacy.write(to: dir.appendingPathComponent(LtTelemetry.legacyDurableFile), atomically: true, encoding: .utf8)
        _ = telemetry()
        try await eventually("legacy sent") { collector.hits.contains { $0.body.contains("exit_low_memory") } }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LtTelemetry.legacyDurableFile).path))
    }

    @Test func aRetryKeepsTheRecordUidSoThePlatformCanDeDuplicate() async throws {
        collector.reset([503])
        let t = telemetry()
        t.send([event("a")])
        try await eventually("retry") { collector.hits.count == 2 }
        #expect(uids(collector.hits[0].body).count == 1)
        #expect(uids(collector.hits[0].body) == uids(collector.hits[1].body))
    }

    @Test func retryAfterIsHonouredAndFlushDoesNotCutItShort() async throws {
        collector.reset([429], retryAfters: ["1"])
        let t = telemetry()
        t.send([event("a")])
        try await eventually("first post") { collector.hits.count == 1 }
        t.flush()
        t.send([event("b")]) // Waits on disk for the retry.
        try await eventually("retry") { collector.hits.count >= 2 }
        #expect(collector.hits[1].at.timeIntervalSince(collector.hits[0].at) >= 0.9)
        try await eventually("b too") { collector.hits.contains { $0.body.contains("\"b\"") } }
    }

    @Test func flushAndDrainCutAClientBackoffShort() async throws {
        collector.reset([0, 0]) // Offline twice (no answer), then delivered.
        let backlog = Lines()
        let t = telemetry(retryMs: 60_000, onBacklog: { backlog.add("backlog") })
        t.send([event("a")])
        try await eventually("first try") { collector.hits.count == 1 }
        try await eventually("backlog") { backlog.all.count == 1 } // Left waiting: the app can plan a background drain.
        #expect(await t.drain(timeoutMs: 5_000) == false) // Still offline.
        #expect(await t.drain(timeoutMs: 5_000))
        #expect(await t.drain(timeoutMs: 5_000)) // Nothing left.
    }

    @Test func dropsAreReportedOnceDeliveryWorks() async throws {
        collector.reset([400])
        let t = telemetry()
        t.send([event("rejected")])
        try await eventually("rejected post") { collector.hits.count == 1 }
        t.send([event("next")])
        try await eventually("drop report") { collector.hits.contains { $0.body.contains("dropped_rejected") } }
        #expect(collector.hits.first { $0.body.contains("dropped_rejected") }!.body.contains("\"telemetry\""))
    }

    @Test func heldRecordsSurviveTheProcessAndAreReturnedOnce() {
        let held = [event("held-1"), Telemetry.appError(AppError(.rtc, "agora_error_17"), stage: "joining", count: 1, atEpochMs: 3)]
        telemetry().writeHeld(held)
        let next = telemetry()
        #expect(next.takeHeld() == held)
        #expect(next.takeHeld().isEmpty)
        next.writeHeld(held); next.writeHeld([])
        #expect(telemetry().takeHeld().isEmpty)
    }

    @Test func aProcessThatDiedAtLaunchMakesTheNextStartWait() async throws {
        collector.reset()
        let log = Lines()
        _ = telemetry(startupWaitMs: 3_000)
        // That process "died" within the launch window: its marker is still there.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LtTelemetry.launchFile).path))
        _ = telemetry(log: log, startupWaitMs: 3_000)
        #expect(log.all.contains { $0.contains("很快就結束") })
    }

    @Test func remoteConfigIsFetchedCachedAndAppliedWithItsVersion() async throws {
        collector.reset()
        collector.serveConfig(#"{"schema":1,"version":4,"telemetry":{"drop_labels":["mic"],"batch_records":7}}"#)
        let t = telemetry()
        try await eventually("config applied") { t.settings.version == 4 }
        #expect(t.settings.batchRecords == 7)
        t.send([Telemetry.appEvent(label: "mic", event: "x", reason: "silenced", atEpochMs: 1), event("kept"),
                Telemetry.appError(AppError(.audio, "x"), stage: "idle", count: 1, atEpochMs: 2)])
        try await eventually("two posts") { collector.hits.count == 2 }
        let bodies = collector.hits.map(\.body).joined()
        #expect(!bodies.contains("\"silenced\"")) // Dropped by label.
        #expect(bodies.contains("\"kept\"") && bodies.contains("app_error"))
        #expect(collector.hits.allSatisfy { $0.body.contains("\"config_version\"") })
        // Next launch: the cached file applies at once, and the fetch sends its ETag (answered 304).
        collector.serveConfig(#"{"schema":1,"version":5}"#)
        let next = telemetry()
        #expect(next.settings.version == 4)
        try await eventually("conditional fetch") { collector.configHits.contains("\"v1\"") }
        #expect(next.settings.version == 4)
    }

    @Test func refreshIsThrottledAndABadFileKeepsTheLastGoodSettings() async throws {
        collector.reset()
        collector.serveConfig(#"{"schema":1,"version":1}"#)
        let t = telemetry()
        try await eventually("first fetch") { t.settings.version == 1 }
        t.refreshConfig(minIntervalMs: 60_000) // Too soon.
        try await Task.sleep(for: .milliseconds(100))
        #expect(collector.configHits.count == 1)
        collector.serveConfig("{broken", etag: "\"v2\"")
        t.refreshConfig(minIntervalMs: 0)
        try await eventually("second fetch") { collector.configHits.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(t.settings.version == 1)
    }

    @Test func theKillSwitchStopsSending() async throws {
        collector.reset()
        collector.serveConfig(#"{"schema":1,"version":9,"telemetry":{"enabled":false}}"#)
        let t = telemetry()
        try await eventually("disabled") { !t.settings.enabled }
        t.send([event("x")])
        try await Task.sleep(for: .milliseconds(150))
        #expect(collector.hits.isEmpty)
    }

    @Test func backoffDoublesUpToTheCapWithJitterAndRetryAfterParses() {
        #expect(LtTelemetry.backoffDelay(failures: 1, base: 10_000, max: 300_000, unit: 0.5) == 10_000)
        #expect(LtTelemetry.backoffDelay(failures: 2, base: 10_000, max: 300_000, unit: 0.5) == 20_000)
        #expect(LtTelemetry.backoffDelay(failures: 20, base: 10_000, max: 300_000, unit: 0.5) == 300_000)
        #expect(LtTelemetry.backoffDelay(failures: 1, base: 10_000, max: 300_000, unit: 0) == 8_000)
        #expect(LtTelemetry.parseRetryAfter("120", nowMs: 0) == 120_000)
        #expect(LtTelemetry.parseRetryAfter("Wed, 21 Oct 2015 07:28:30 GMT", nowMs: 1_445_412_480_000) == 30_000)
        #expect(LtTelemetry.parseRetryAfter("soon", nowMs: 0) == nil)
        #expect(LtTelemetry.retryable(0) && LtTelemetry.retryable(429) && LtTelemetry.retryable(503))
        #expect(!LtTelemetry.retryable(400) && !LtTelemetry.retryable(401))
    }

    @Test func offWithoutUrlOrWithHttpWhenHttpsIsRequired() async throws {
        collector.reset()
        let log = Lines()
        let insecure = telemetry(requireHttps: true, log: log)
        #expect(!insecure.enabled)
        #expect(log.all.count == 1 && !log.all[0].contains("collector.test"))
        #expect(!telemetry(url: " ").enabled)
        insecure.send([event("x")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(collector.hits.isEmpty)
    }

    @Test func callMarkerIsWrittenReadAndCleared() {
        let t = telemetry()
        let marker = CallMarker(callId: "c-1", channel: "room", user: "1001", engine: "agora", sdkVersion: "agora-4.6.0", startedAtMs: 42)
        t.writeCallMarker(marker.encode())
        #expect(CallMarker.decode(telemetry().readCallMarker()) == marker)
        t.writeCallMarker(nil)
        #expect(t.readCallMarker() == nil)
    }
}
