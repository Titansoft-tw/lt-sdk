import Foundation
import Testing
@testable import LtTelemetry

/// Answers every request from `StubCollector` instead of the network.
final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = StubCollector.shared.receive(request)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class StubCollector: @unchecked Sendable {
    static let shared = StubCollector()
    struct Hit { let body: String; let auth: String? }
    private let lock = NSLock()
    private var _hits: [Hit] = []
    /// Statuses to answer with, in order (0 = no answer); 200 once they run out.
    private var statuses: [Int] = []
    var hits: [Hit] { lock.withLock { _hits } }
    func reset(_ statuses: [Int] = []) { lock.withLock { _hits = []; self.statuses = statuses } }
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

    private func telemetry(url: String? = "http://collector.test/v1/logs", requireHttps: Bool = false, log: Lines = Lines()) -> LtTelemetry {
        LtTelemetry(TelemetryConfig(logsUrl: url, headers: { ["Authorization": "Bearer t0k"] }, requireHttps: requireHttps,
                                    serviceName: "unit-test", device: device, storageDir: dir, log: { log.add($0) }),
                    retrySeconds: 0.05, protocolClasses: [StubProtocol.self])
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

    @Test func durableRecordsSurviveARestart() async throws {
        collector.reset()
        let error = Telemetry.appError(AppError(.api, "http_503"), stage: "idle", count: 1, atEpochMs: 1)
        let down = telemetry(url: "http://down.test/v1/logs")
        down.send([error])
        let file = dir.appendingPathComponent("telemetry-durable.json")
        try await eventually("durable file") { FileManager.default.fileExists(atPath: file.path) }
        _ = telemetry() // Next launch, collector reachable.
        try await eventually("sent at launch") { collector.hits.contains { $0.body.contains("http_503") } }
        try await eventually("file removed") { !FileManager.default.fileExists(atPath: file.path) }
        _ = down
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
