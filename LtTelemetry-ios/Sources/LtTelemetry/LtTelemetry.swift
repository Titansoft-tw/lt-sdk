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
    /// Holds the record queue and the call marker; use one that is not a cache (Application Support).
    public var storageDir: URL
    /// Called only when delivery changes between working and failing; never gets the URL or a header. Any thread.
    public var log: @Sendable (String) -> Void
    /// Disk the queue may use; over it the oldest quality_second go first, app_error last (`TelemetryStore`).
    public var maxQueueBytes: Int64
    /// Records not delivered within this long are dropped (counted in the `telemetry/dropped` report).
    public var maxQueueAgeMs: Int64
    /// When the previous process died within `LtTelemetry.startupWindowMs` of starting (a crash loop at launch), the
    /// initializer waits up to this long for the first delivery attempt, so the records about that crash go out before
    /// this process can crash too (Sentry's app-start crash detection). 0 turns it off. Keep it well under the watchdog.
    public var startupCrashWaitMs: Int64
    /// Called (any thread) whenever records are left waiting for a retry, e.g. to plan a background drain. Must not block.
    public var onBacklog: @Sendable () -> Void
    /// Remote telemetry config (`RemoteTelemetryConfig`): nil derives `<base>/config/telemetry.json` from a `logsUrl`
    /// ending in `/v1/logs`; empty turns it off. Fetched with the same `headers`.
    public var configUrl: String?
    /// `debug` or `release`: what the config's rules match `build` against.
    public var buildType: String

    public init(logsUrl: String?, headers: @escaping @Sendable () -> [String: String] = { [:] }, requireHttps: Bool, serviceName: String,
                device: StaticDevice, storageDir: URL, log: @escaping @Sendable (String) -> Void = { _ in },
                maxQueueBytes: Int64 = TelemetryStore.defaultMaxBytes, maxQueueAgeMs: Int64 = TelemetryStore.defaultMaxAgeMs,
                startupCrashWaitMs: Int64 = 2_000, onBacklog: @escaping @Sendable () -> Void = {},
                configUrl: String? = nil, buildType: String = "release") {
        self.logsUrl = logsUrl; self.headers = headers; self.requireHttps = requireHttps; self.serviceName = serviceName
        self.device = device; self.storageDir = storageDir; self.log = log
        self.maxQueueBytes = maxQueueBytes; self.maxQueueAgeMs = maxQueueAgeMs; self.startupCrashWaitMs = startupCrashWaitMs
        self.onBacklog = onBacklog; self.configUrl = configUrl; self.buildType = buildType
    }
}

/// Posts `TelemetryRecord`s to the Collector, fire and forget. Every record is written to disk first (`TelemetryStore`)
/// and sent from there by a background actor, so a crash or a killed process loses nothing: what is left goes out when
/// the next process starts (or on `flush` / `drain`). Same rules as Android's LtTelemetry.kt.
///
/// Delivery: one segment (at most 200 records) per POST, most important lane first. 2xx deletes it; any other 4xx drops
/// it (it would block everything behind it); no answer, 408, 429 or 5xx keeps it and retries after 10 s doubling up to
/// 5 min with ±20% jitter, or after the server's `Retry-After`. While a retry is pending, new records only go to disk.
/// Dropped records are reported once delivery works again (`telemetry/dropped`). The API is main-actor, like the app's
/// controller; `send` writes to disk on the caller's thread before it returns.
@MainActor public final class LtTelemetry {
    nonisolated public static let retryMs: Int64 = 10_000
    nonisolated public static let maxRetryMs: Int64 = 5 * 60_000
    /// A server asking for longer than this is capped (a stuck header must not silence telemetry for days).
    nonisolated public static let maxRetryAfterMs: Int64 = 60 * 60_000
    /// A process that ends within this long of starting counts as a crash at launch (`TelemetryConfig.startupCrashWaitMs`).
    nonisolated public static let startupWindowMs: Int64 = 5_000
    nonisolated public static let queueDir = "telemetry-queue"
    /// Where versions before the disk queue kept app_error / abnormal_exit; imported once.
    nonisolated public static let legacyDurableFile = "telemetry-durable.json"
    nonisolated public static let heldFile = "telemetry-held.jsonl"
    nonisolated public static let launchFile = "telemetry-launch.txt"
    nonisolated public static let configPath = "/config/telemetry.json"
    nonisolated public static let configFile = "telemetry-config.json"
    nonisolated public static let configEtagFile = "telemetry-config.etag"
    nonisolated public static let bucketFile = "telemetry-bucket.txt"
    /// Attribute on every record sent under a remote config: its `version`.
    nonisolated public static let configVersion = "config_version"
    nonisolated public static let labelTelemetry = "telemetry"
    nonisolated public static let reasonDropped = "dropped"

    private let config: TelemetryConfig
    private let url: URL?
    private let store: TelemetryStore?
    private let delivery: Delivery?
    private let settingsBox: SettingsBox
    private let configUrl: URL?
    private let clock: @Sendable () -> Int64
    private var lastConfigFetch: Int64 = 0
    private let files = FileManager.default

    /// The settings in effect: the last good remote config (from disk at start), or the defaults.
    public var settings: TelemetrySettings { settingsBox.value }
    public var enabled: Bool { url != nil }

    public convenience init(_ config: TelemetryConfig) {
        self.init(config, retryMs: Self.retryMs, maxRetryMs: Self.maxRetryMs, jitter: { Double.random(in: 0..<1) }, protocolClasses: nil)
    }

    /// `protocolClasses`: tests answer with a URLProtocol instead of the network.
    init(_ config: TelemetryConfig, retryMs: Int64, maxRetryMs: Int64, jitter: @escaping @Sendable () -> Double, protocolClasses: [AnyClass]?,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.config = config
        self.clock = clock
        let raw = (config.logsUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            url = nil
        } else if config.requireHttps && !raw.hasPrefix("https://") {
            config.log("遙測網址不是 https，已關閉遙測")
            url = nil
        } else {
            url = URL(string: raw)
        }
        try? files.createDirectory(at: config.storageDir, withIntermediateDirectories: true)
        configUrl = url.flatMap { logs in
            if let explicit = config.configUrl {
                let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(string: trimmed)
            }
            var text = logs.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            guard text.hasSuffix("/v1/logs") else { return nil }
            return URL(string: String(text.dropLast("/v1/logs".count)) + Self.configPath)
        }
        let target = ConfigTarget(platform: config.device.platform, appVersion: config.device.appVersion, build: config.buildType)
        let bucket = Self.bucket(config.storageDir)
        let cached = configUrl == nil ? nil : (try? String(contentsOf: config.storageDir.appendingPathComponent(Self.configFile), encoding: .utf8))
            .flatMap { RemoteTelemetryConfig.parse($0, target: target, bucket: bucket) }
        let settings = cached ?? TelemetrySettings()
        settingsBox = SettingsBox(settings)

        guard let url else { store = nil; delivery = nil; return }
        let remote = settings.version != nil
        let store = TelemetryStore(dir: config.storageDir.appendingPathComponent(Self.queueDir),
                                   maxBytes: remote ? settings.queueMaxBytes : config.maxQueueBytes,
                                   maxAgeMs: remote ? settings.queueMaxAgeMs : config.maxQueueAgeMs, clock: clock)
        self.store = store
        let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 5
            configuration.urlCache = nil
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            return URLSession(configuration: configuration)
        }()
        let headers = config.headers
        let post: @Sendable (Data) async -> PostResult = { body in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers() { request.setValue(value, forHTTPHeaderField: key) }
            request.httpBody = body
            guard let response = (try? await session.data(for: request))?.1 as? HTTPURLResponse else { return PostResult(status: 0) }
            let retryAfter = LtTelemetry.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), nowMs: clock())
            return PostResult(status: response.statusCode, retryAfterMs: retryAfter)
        }
        var fetch: (@Sendable (String?) async -> (String, String?)?)?
        if let configUrl {
            fetch = { etag in
                var request = URLRequest(url: configUrl)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                for (key, value) in headers() { request.setValue(value, forHTTPHeaderField: key) }
                if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
                      http.statusCode == 200, data.count <= 64 * 1024 else { return nil }
                return (String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "ETag"))
            }
        }
        let delivery = Delivery(
            store: store, settings: settingsBox, device: config.device, serviceName: config.serviceName, log: config.log,
            onBacklog: config.onBacklog, clock: clock, jitter: jitter, retryMs: retryMs, maxRetryMs: maxRetryMs,
            post: post, fetchConfig: fetch, configStore: ConfigFiles(dir: config.storageDir), target: target, bucket: bucket)
        self.delivery = delivery

        // The launch marker lives for startupWindowMs: still there at the next start = that process died early.
        let launch = config.storageDir.appendingPathComponent(Self.launchFile)
        let crashedAtLaunch = config.startupCrashWaitMs > 0 && files.fileExists(atPath: launch.path)
        try? "\(clock())".write(to: launch, atomically: true, encoding: .utf8)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(Self.startupWindowMs))
            try? FileManager.default.removeItem(at: launch)
        }
        importLegacyQueue(into: store)
        // What the last process could not send. After a crash at launch, wait for that first pass (it runs off the
        // main actor, so blocking here cannot deadlock it).
        let firstPass = DispatchSemaphore(value: 0)
        let waitMs: Int64 = config.startupCrashWaitMs
        let passTimeoutMs: Int64 = waitMs > 0 ? waitMs : 30_000
        Task.detached {
            _ = await delivery.drain(timeoutMs: passTimeoutMs)
            firstPass.signal()
        }
        if crashedAtLaunch {
            config.log("上次啟動後很快就結束，先送出遙測再繼續")
            _ = firstPass.wait(timeout: .now() + .milliseconds(Int(waitMs)))
        }
        refreshConfig(minIntervalMs: 0)
    }

    /// Fire and forget: written to disk before it returns, sent in the background. Never throws.
    public func send(_ records: [TelemetryRecord]) {
        guard let store, let delivery else { return }
        let now = settings
        guard now.enabled, !records.isEmpty else { return }
        let kept = records.filter { r in
            r.body != Telemetry.sdkEvent || !now.dropLabels.contains(r.attributes["label"] ?? "") || TelemetryStore.Lane.of(r) == .critical
        }.map { r in
            guard let version = now.version else { return r }
            return TelemetryRecord(body: r.body, atEpochMs: r.atEpochMs,
                                   attributes: r.attributes.merging([Self.configVersion: String(version)]) { _, new in new }, severity: r.severity)
        }
        guard !kept.isEmpty else { return }
        store.append(kept)
        Task { await delivery.schedule(now: false) }
    }

    /// Try now: call when the network comes back or the app goes to the background. Cuts a client-side backoff short,
    /// but not a server's Retry-After.
    public func flush() {
        guard let delivery else { return }
        Task { await delivery.schedule(now: true) }
    }

    /// Sends what is queued now and waits up to `timeoutMs` for that pass (e.g. inside a background task). True when the
    /// queue is empty afterwards. False at once while the server's Retry-After runs.
    public func drain(timeoutMs: Int64) async -> Bool {
        guard let delivery else { return true }
        return await delivery.drain(timeoutMs: timeoutMs)
    }

    /// Fetches the remote config in the background unless the last fetch was less than `minIntervalMs` ago (the app:
    /// every call start with a short interval, coming to the foreground with 15 minutes). Sends `If-None-Match`, so an
    /// unchanged file costs a 304. What it changes applies from the next record on; queue limits from the next launch.
    public func refreshConfig(minIntervalMs: Int64) {
        guard configUrl != nil, let delivery else { return }
        let now = clock()
        if lastConfigFetch != 0 && now - lastConfigFetch < minIntervalMs { return }
        lastConfigFetch = now
        Task { await delivery.fetchConfig() }
    }

    /// Records the app holds back until their call_id is final (the controller's outbox), kept on disk so a crash before
    /// that does not lose them: rewritten whenever the held set changes, empty clears it. `takeHeld` at the next launch
    /// returns them once.
    public func writeHeld(_ records: [TelemetryRecord]) {
        guard store != nil else { return }
        let file = config.storageDir.appendingPathComponent(Self.heldFile)
        if records.isEmpty { try? files.removeItem(at: file); return }
        try? records.compactMap(TelemetryStore.encode).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    public func takeHeld() -> [TelemetryRecord] {
        let file = config.storageDir.appendingPathComponent(Self.heldFile)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        try? files.removeItem(at: file)
        return text.split(separator: "\n").compactMap(TelemetryStore.decode)
    }

    /// The on-disk call marker (`CallMarker`); nil clears it. Survives the process.
    public func writeCallMarker(_ text: String?) {
        let file = config.storageDir.appendingPathComponent("call-marker.json")
        if let text, !text.isEmpty { try? text.write(to: file, atomically: true, encoding: .utf8) } else { try? files.removeItem(at: file) }
    }
    public func readCallMarker() -> String? {
        try? String(contentsOf: config.storageDir.appendingPathComponent("call-marker.json"), encoding: .utf8)
    }

    /// The queue (tests).
    var queue: TelemetryStore? { store }

    /// Moves app_error / abnormal_exit left in the previous version's telemetry-durable.json into the queue.
    private func importLegacyQueue(into store: TelemetryStore) {
        struct Stored: Decodable { let body: String, at: Int64, severity: String, attributes: [String: String] }
        let file = config.storageDir.appendingPathComponent(Self.legacyDurableFile)
        guard let data = try? Data(contentsOf: file) else { return }
        let records = ((try? JSONDecoder().decode([Stored].self, from: data)) ?? [])
            .map { TelemetryRecord(body: $0.body, atEpochMs: $0.at, attributes: $0.attributes, severity: $0.severity) }
        store.append(records)
        try? files.removeItem(at: file)
    }

    /// This install's rollout bucket (0–99): local only, never sent.
    private static func bucket(_ dir: URL) -> Int {
        let file = dir.appendingPathComponent(bucketFile)
        if let text = try? String(contentsOf: file, encoding: .utf8), let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           (0...99).contains(n) { return n }
        let n = Int.random(in: 0...99)
        try? String(n).write(to: file, atomically: true, encoding: .utf8)
        return n
    }

    nonisolated static func retryable(_ status: Int) -> Bool { status == 0 || status == 408 || status == 429 || status >= 500 }

    /// `base` × 2^(failures−1), capped at `max`, then ±20% (`unit` is a random number in [0, 1)).
    nonisolated static func backoffDelay(failures: Int, base: Int64, max: Int64, unit: Double) -> Int64 {
        let raw = Swift.min(Double(base) * pow(2, Double(Swift.min(Swift.max(failures - 1, 0), 30))), Double(max))
        return Int64(raw * (0.8 + 0.4 * unit))
    }

    /// `Retry-After: <seconds>` or an HTTP date; nil when absent or unreadable.
    nonisolated static func parseRetryAfter(_ value: String?, nowMs: Int64) -> Int64? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Int64(text) { return Swift.max(seconds * 1000, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return Swift.max(Int64(date.timeIntervalSince1970 * 1000) - nowMs, 0)
    }
}

/// HTTP status (0 = no answer) and the Retry-After delay, if any.
struct PostResult: Sendable {
    let status: Int
    var retryAfterMs: Int64?
}

/// The settings in effect, read by the main actor (`send`) and the delivery actor.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: TelemetrySettings
    init(_ value: TelemetrySettings) { _value = value }
    var value: TelemetrySettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// The last good config file and its ETag on disk.
struct ConfigFiles: Sendable {
    let dir: URL
    var etag: String? {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(LtTelemetry.configFile).path) else { return nil }
        return (try? String(contentsOf: dir.appendingPathComponent(LtTelemetry.configEtagFile), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    func save(_ body: String, etag: String?) {
        try? body.write(to: dir.appendingPathComponent(LtTelemetry.configFile), atomically: true, encoding: .utf8)
        let etagUrl = dir.appendingPathComponent(LtTelemetry.configEtagFile)
        if let etag, !etag.isEmpty { try? etag.write(to: etagUrl, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: etagUrl) }
    }
}

/// Fired once, by whichever comes first: the end of an upload pass or a timeout.
final class PassSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    func attach(_ c: CheckedContinuation<Void, Never>) {
        let now = lock.withLock { () -> Bool in
            if fired { return true }
            continuation = c
            return false
        }
        if now { c.resume() }
    }
    func fire() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if fired { return nil }
            fired = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}

/// Sends from the disk queue, one pass at a time, off the main actor.
actor Delivery {
    private let store: TelemetryStore
    private let settings: SettingsBox
    private let device: StaticDevice
    private let serviceName: String
    private let log: @Sendable (String) -> Void
    private let onBacklog: @Sendable () -> Void
    private let clock: @Sendable () -> Int64
    private let jitter: @Sendable () -> Double
    private let retryMs: Int64
    private let maxRetryMs: Int64
    private let post: @Sendable (Data) async -> PostResult
    private let fetch: (@Sendable (String?) async -> (String, String?)?)?
    private let configStore: ConfigFiles
    private let target: ConfigTarget
    private let bucket: Int

    private var telemetryOk: Bool?
    private var failures = 0
    private var retryTask: Task<Void, Never>?
    /// The pending retry was set by the server (Retry-After); `flush` does not cut it short.
    private var serverDelay = false
    private var running = false
    private var again = false
    private var waiters: [PassSignal] = []

    init(store: TelemetryStore, settings: SettingsBox, device: StaticDevice, serviceName: String, log: @escaping @Sendable (String) -> Void,
         onBacklog: @escaping @Sendable () -> Void, clock: @escaping @Sendable () -> Int64, jitter: @escaping @Sendable () -> Double,
         retryMs: Int64, maxRetryMs: Int64, post: @escaping @Sendable (Data) async -> PostResult,
         fetchConfig: (@Sendable (String?) async -> (String, String?)?)?, configStore: ConfigFiles, target: ConfigTarget, bucket: Int) {
        self.store = store; self.settings = settings; self.device = device; self.serviceName = serviceName; self.log = log
        self.onBacklog = onBacklog; self.clock = clock; self.jitter = jitter; self.retryMs = retryMs; self.maxRetryMs = maxRetryMs
        self.post = post; self.fetch = fetchConfig; self.configStore = configStore; self.target = target; self.bucket = bucket
    }

    func schedule(now: Bool) {
        if retryTask != nil {
            if !now || serverDelay { return }
            retryTask?.cancel()
            retryTask = nil
        }
        if running { again = true; return }
        running = true
        Task { await self.run() }
    }

    func drain(timeoutMs: Int64) async -> Bool {
        if retryTask != nil && serverDelay { return false }
        let signal = PassSignal()
        waiters.append(signal)
        schedule(now: true)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            signal.fire()
        }
        await withCheckedContinuation { signal.attach($0) }
        return store.isEmpty
    }

    private func run() async {
        repeat {
            again = false
            await pass()
        } while again && retryTask == nil
        running = false
        let done = waiters
        waiters = []
        done.forEach { $0.fire() }
    }

    /// Sends batch after batch until the queue is empty or one fails.
    private func pass() async {
        if retryTask != nil { return }
        if !settings.value.enabled { return } // Remote kill switch: the queue waits (until it expires).
        while let batch = store.next() {
            guard let body = try? JSONSerialization.data(withJSONObject: Telemetry.logsJson(
                batch.records, device: device, serviceName: serviceName, observedEpochMs: clock())) else {
                store.complete(batch, sent: false)
                continue
            }
            let result = await post(body)
            let ok = (200..<300).contains(result.status)
            if ok != telemetryOk { telemetryOk = ok; log(ok ? "遙測已送達 lt-observability" : "遙測上報失敗（不影響通話），稍後重送") }
            if ok {
                store.complete(batch, sent: true)
                failures = 0
                // Losses are reported once there is a working path to report them on.
                let dropped = store.takeDropped()
                if !dropped.isEmpty {
                    var extra: [String: String] = [:]
                    for (reason, n) in dropped { extra["dropped_\(reason.rawValue)"] = String(n) }
                    store.append([Telemetry.appEvent(label: LtTelemetry.labelTelemetry, event: "telemetry records dropped",
                                                     reason: LtTelemetry.reasonDropped, atEpochMs: clock(), extra: extra)])
                }
            } else if LtTelemetry.retryable(result.status) {
                store.release(batch)
                backOff(result.retryAfterMs)
                onBacklog()
                return
            } else {
                // A permanent rejection (bad token, bad payload) would block every later record, so that batch is dropped.
                store.complete(batch, sent: false)
            }
        }
    }

    private func backOff(_ retryAfterMs: Int64?) {
        failures += 1
        let remote = settings.value.version != nil ? settings.value : nil
        let base = remote?.retryBaseMs ?? retryMs
        let delay = retryAfterMs.map { min(max($0, base), LtTelemetry.maxRetryAfterMs) }
            ?? LtTelemetry.backoffDelay(failures: failures, base: base, max: remote?.retryMaxMs ?? maxRetryMs, unit: jitter())
        serverDelay = retryAfterMs != nil
        retryTask = Task {
            try? await Task.sleep(for: .milliseconds(delay))
            if Task.isCancelled { return }
            self.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        serverDelay = false
        schedule(now: false)
    }

    /// Keeps the last good config on disk; a bad or missing file changes nothing.
    func fetchConfig() async {
        guard let fetch, let (body, etag) = await fetch(configStore.etag) else { return }
        guard let parsed = RemoteTelemetryConfig.parse(body, target: target, bucket: bucket) else {
            log("遙測設定檔格式不符，沿用目前設定")
            return
        }
        configStore.save(body, etag: etag)
        if parsed.version != settings.value.version { log("已套用遙測設定 v\(parsed.version ?? 0)") }
        settings.value = parsed
    }
}
