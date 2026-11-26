import Foundation

public struct TelemetryConfig: Sendable {
    /// The full URL (e.g. https://otel.example/v1/logs); nil or empty turns telemetry off and every call is a no-op.
    public var logsUrl: String?
    /// Called before every batch; today it returns `Authorization: Bearer <OTLP_TOKEN>`.
    public var headers: @Sendable () -> [String: String]
    /// Release builds pass true: a URL that is not https turns telemetry off (one log line).
    public var requireHttps: Bool
    /// `service.name`, e.g. "lt-call-demo"; no default on purpose.
    public var serviceName: String
    public var device: StaticDevice
    /// Holds the durable queue and the call marker; use one that is not a cache (Application Support).
    public var storageDir: URL
    /// Called only when delivery changes between working and failing; never gets the URL or a header.
    public var log: @Sendable (String) -> Void
    public init(logsUrl: String?, headers: @escaping @Sendable () -> [String: String] = { [:] }, requireHttps: Bool, serviceName: String,
                device: StaticDevice, storageDir: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logsUrl = logsUrl; self.headers = headers; self.requireHttps = requireHttps; self.serviceName = serviceName
        self.device = device; self.storageDir = storageDir; self.log = log
    }
}

/// Posts `TelemetryRecord`s to the Collector, fire and forget. Records that cannot be sent wait in memory (newest
/// `maxUnsent` kept) and go out with the next batch; app_error and abnormal_exit go through a file first
/// (`DurableTelemetryQueue`) so a killed process sends them at the next launch. Main actor, like the app's controller.
@MainActor public final class LtTelemetry {
    public static let maxUnsent = 1_800
    public static let chunk = 200
    private let config: TelemetryConfig
    private let url: URL?
    private let retrySeconds: Double
    private let session: URLSession
    private var telemetryOk: Bool?
    private var unsent: [TelemetryRecord] = []
    private var sending = false
    private var retryScheduled = false
    private var durableRetry = false
    private let markerStore: FileStore
    private lazy var durable = DurableTelemetryQueue(store: FileStore(config.storageDir.appendingPathComponent("telemetry-durable.json")))

    public convenience init(_ config: TelemetryConfig) { self.init(config, retrySeconds: 10, protocolClasses: nil) }

    /// `protocolClasses`: tests answer with a URLProtocol instead of the network.
    init(_ config: TelemetryConfig, retrySeconds: Double, protocolClasses: [AnyClass]?) {
        self.config = config
        self.retrySeconds = retrySeconds
        let raw = (config.logsUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            url = nil
        } else if config.requireHttps && !raw.hasPrefix("https://") {
            config.log("遙測網址不是 https，已關閉遙測")
            url = nil
        } else {
            url = URL(string: raw)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: config.storageDir, withIntermediateDirectories: true)
        markerStore = FileStore(config.storageDir.appendingPathComponent("call-marker.json"))
        if url != nil { Task { await drainDurable() } } // What the last process could not send.
    }

    public var enabled: Bool { url != nil }

    /// Fire and forget: never blocks or throws.
    public func send(_ records: [TelemetryRecord]) {
        guard url != nil else { return }
        let lasting = records.filter(DurableTelemetryQueue.isDurable)
        if !lasting.isEmpty { durable.add(lasting); Task { await drainDurable() } }
        let records = records.filter { !DurableTelemetryQueue.isDurable($0) }
        if records.isEmpty { return }
        unsent = Array((unsent + records).suffix(Self.maxUnsent))
        // While a retry is pending the collector is known to be unreachable; new records just wait for it.
        if !retryScheduled { flushUnsent() }
    }

    /// The on-disk call marker (`CallMarker`); nil clears it. Survives the process.
    public func writeCallMarker(_ text: String?) { markerStore.write(text ?? "") }
    public func readCallMarker() -> String? { markerStore.read() }

    /// Sends the queue oldest first in small chunks, one at a time; stops at the first failure and retries later on its own.
    private func flushUnsent() {
        guard !sending, !unsent.isEmpty else { return }
        let batch = Array(unsent.prefix(Self.chunk))
        unsent.removeFirst(batch.count)
        sending = true
        Task {
            let status = await post(batch)
            let ok = (200..<300).contains(status)
            sending = false
            // A permanent rejection (bad token, bad payload) would block every later record, so that chunk is dropped.
            if !ok && Self.retryable(status) {
                unsent = Array((batch + unsent).suffix(Self.maxUnsent))
                scheduleRetry()
            } else {
                flushUnsent()
            }
            // Sent every few seconds, so only a change of outcome is logged.
            if ok != telemetryOk { telemetryOk = ok; config.log(ok ? "遙測已送達 lt-observability" : "遙測上報失敗（不影響通話）") }
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(retrySeconds))
            retryScheduled = false
            flushUnsent()
        }
    }

    private func drainDurable() async {
        let done = await durable.drain { batch in
            let status = await self.post(batch)
            if (200..<300).contains(status) { return .sent }
            return Self.retryable(status) ? .retry : .rejected
        }
        if !done && !durableRetry {
            durableRetry = true
            Task {
                try? await Task.sleep(for: .seconds(retrySeconds * 3))
                durableRetry = false
                await drainDurable()
            }
        }
    }

    /// HTTP status, 0 when there was no answer.
    private func post(_ batch: [TelemetryRecord]) async -> Int {
        guard let url, let body = try? JSONSerialization.data(withJSONObject: Telemetry.logsJson(batch, device: config.device,
                                                                                                   serviceName: config.serviceName)) else { return 400 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in config.headers() { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func retryable(_ status: Int) -> Bool { status == 0 || status == 408 || status == 429 || status >= 500 }

    private final class FileStore: TextStore {
        let url: URL
        init(_ url: URL) { self.url = url }
        func read() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func write(_ text: String) {
            if text.isEmpty { try? FileManager.default.removeItem(at: url) }
            else { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
