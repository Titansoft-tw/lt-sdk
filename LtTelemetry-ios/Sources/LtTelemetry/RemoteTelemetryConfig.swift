import Foundation

/// What the remote telemetry config (`<collector base>/config/telemetry.json`, schema 1; lt-call-demo
/// docs/telemetry-delivery-proposal.md §4.3) lets the server change without an app release. Every value is clamped to
/// a safe range, so no file, however wrong, can break the app or flood the collector. `version` is nil while only the
/// built-in defaults apply; otherwise records carry it as `config_version`. Same rules as Android's
/// RemoteTelemetryConfig.kt.
public struct TelemetrySettings: Equatable, Sendable {
    public var enabled = true
    /// Send one quality_second every N seconds (the on-screen diagnostics stay per second). Next call.
    public var qualityEverySec = 1
    /// Share of calls that send quality_second at all; events and errors are always sent. Next call.
    public var callSamplePercent = 100
    /// quality_second records batched per send (the controller's outbox). Next call.
    public var batchRecords = 3
    public var retryBaseMs: Int64 = LtTelemetry.retryMs
    public var retryMaxMs: Int64 = LtTelemetry.maxRetryMs
    /// Disk queue limits; take effect at the next launch.
    public var queueMaxBytes: Int64 = TelemetryStore.defaultMaxBytes
    public var queueMaxAgeMs: Int64 = TelemetryStore.defaultMaxAgeMs
    /// sdk_event labels not to send; never affects app_error or abnormal_exit.
    public var dropLabels: Set<String> = []
    public var version: Int?
    public init() {}
}

/// What the rules match on: `android` / `ios`, the app's version name, `debug` / `release`.
public struct ConfigTarget: Equatable, Sendable {
    public let platform: String, appVersion: String, build: String
    public init(platform: String, appVersion: String, build: String) {
        self.platform = platform; self.appVersion = appVersion; self.build = build
    }
}

public enum RemoteTelemetryConfig {
    public static let schema = 1
    public static let maxDropLabels = 50

    /// The settings `json` gives `target`, or nil when the file is unusable (not JSON, not an object, schema ≠ 1, no
    /// integer version): the caller then keeps its last good settings. `bucket` (0–99) is this install's local rollout
    /// bucket; a rule with `rollout_percent` applies only when bucket < percent. Unknown fields are ignored.
    public static func parse(_ json: String, target: ConfigTarget, bucket: Int) -> TelemetrySettings? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              number(root["schema"]) == Double(schema),
              let v = number(root["version"]), v >= 0, v == v.rounded(), v <= Double(Int32.max) else { return nil }
        var merged = root["telemetry"] as? [String: Any] ?? [:]
        for case let rule as [String: Any] in root["rules"] as? [Any] ?? [] {
            guard matches(rule["match"] as? [String: Any], target) else { continue }
            let percent = min(max(number(rule["rollout_percent"]) ?? 100, 0), 100)
            guard Double(bucket) < percent else { continue }
            merged.merge(rule["telemetry"] as? [String: Any] ?? [:]) { _, new in new }
        }
        return settings(merged, version: Int(v))
    }

    private static func settings(_ m: [String: Any], version: Int) -> TelemetrySettings {
        let d = TelemetrySettings()
        func int(_ key: String, _ fallback: Int64, _ low: Int64, _ high: Int64) -> Int64 {
            guard let n = number(m[key]), n.isFinite else { return fallback }
            return min(max(Int64(n.rounded(.towardZero).clamped(-1e15, 1e15)), low), high)
        }
        var s = TelemetrySettings()
        if let b = m["enabled"], isBool(b) { s.enabled = (b as? Bool) ?? true }
        s.qualityEverySec = Int(int("quality_every_s", Int64(d.qualityEverySec), 1, 10))
        s.callSamplePercent = Int(int("call_sample_percent", Int64(d.callSamplePercent), 0, 100))
        s.batchRecords = Int(int("batch_records", Int64(d.batchRecords), 1, 30))
        let base = int("retry_base_s", d.retryBaseMs / 1000, 5, 300)
        s.retryBaseMs = base * 1000
        s.retryMaxMs = int("retry_max_s", d.retryMaxMs / 1000, base, 3600) * 1000
        s.queueMaxBytes = int("queue_max_kb", d.queueMaxBytes / 1024, 512, 20_480) * 1024
        s.queueMaxAgeMs = int("queue_max_age_h", d.queueMaxAgeMs / 3_600_000, 1, 720) * 3_600_000
        s.dropLabels = Set(((m["drop_labels"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(maxDropLabels))
        s.version = version
        return s
    }

    private static func matches(_ match: [String: Any]?, _ target: ConfigTarget) -> Bool {
        guard let match else { return true }
        if let p = match["platform"] as? String, p.lowercased() != target.platform.lowercased() { return false }
        if let b = match["build"] as? String, b.lowercased() != target.build.lowercased() { return false }
        if let low = match["app_version_min"] as? String, compareVersions(target.appVersion, low) < 0 { return false }
        if let below = match["app_version_below"] as? String, compareVersions(target.appVersion, below) >= 0 { return false }
        return true
    }

    /// Numeric, segment by segment ("1.10.0" > "1.9"); a segment's leading digits count, the rest ("0-debug") is ignored.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
                .map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// JSONSerialization gives NSNumber for both numbers and booleans: a boolean is not a number here.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        return n.doubleValue
    }
    private static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}

/// Which per-second samples one call sends, from the `TelemetrySettings` in effect when it started (fixed for the
/// call, so its data stays consistent). `roll` is a random 0–99 drawn per call for `call_sample_percent`.
public struct QualitySampling: Sendable {
    /// Whether this call sends quality_second at all.
    public let sendsQuality: Bool
    /// quality_second records to batch before a send.
    public let batch: Int
    private let every: Int
    private var seen = 0
    public init(_ settings: TelemetrySettings, roll: Int) {
        sendsQuality = roll < settings.callSamplePercent
        batch = settings.batchRecords
        every = max(1, settings.qualityEverySec)
    }
    /// Call once per measured sample: true for the first and then every `qualityEverySec`-th.
    public mutating func take() -> Bool {
        guard sendsQuality else { return false }
        defer { seen += 1 }
        return seen % every == 0
    }
}
