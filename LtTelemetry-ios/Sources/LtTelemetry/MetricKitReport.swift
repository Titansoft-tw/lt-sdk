import Foundation
import LtDeviceInfo

// iOS MetricKit (phase 2, docs/error-device-telemetry.md「MetricKit」). LtDeviceInfo's MetricKitSource turns the payloads into
// MetricKitDiagnostics / MetricKitExits; the rules here are plain code, tested with fake values.

public enum MetricKitReport {
    /// `cumulativeMemoryResourceLimitExitCount` → `memory_resource_limit_exit` (contract decision 2: drop
    /// `cumulative` and `Count`, then snake_case). `CPU` stays one word: `cumulativeCPUResourceLimitExitCount` → `cpu_resource_limit_exit`.
    public static func exitName(_ apple: String) -> String {
        var name = apple
        if name.hasPrefix("cumulative") { name.removeFirst("cumulative".count) }
        if name.hasSuffix("Count") { name.removeLast("Count".count) }
        var out = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            if c.isUppercase && i > 0 {
                let previousUpper = chars[i - 1].isUppercase
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // Start of a word: after a lowercase letter, or the last capital of an acronym followed by lowercase.
                if !previousUpper || nextLower { out.append("_") }
            }
            out.append(contentsOf: c.lowercased())
        }
        return out
    }

    /// Hangs → `app_error WARN domain=crash code=hang`; crashes → `app_error code=crash` only when Sentry is not
    /// running (it reports crashes itself, contract decision P4). No call identity: the payload arrives up to a day later.
    public static func errors(_ diagnostics: MetricKitDiagnostics, sentryEnabled: Bool) -> [AppError] {
        var errors = diagnostics.hangsMs.map {
            AppError(.crash, "hang", detail: "hang_ms=\($0)", severity: Severity.warn)
        }
        if !sentryEnabled {
            errors += diagnostics.crashes.map { AppError(.crash, "crash", detail: "metrickit \($0)", fatal: true, severity: Severity.fatal) }
        }
        return errors
    }

    /// One `sdk_event label=app_exit_daily` per MXMetricPayload: `fg_<name>` / `bg_<name>` counts as integers.
    public static func dailyExits(_ exits: MetricKitExits, atEpochMs: Int64) -> TelemetryRecord {
        var extra: [String: String] = [:]
        for (key, count) in exits.foreground { extra["fg_" + exitName(key)] = String(count) }
        for (key, count) in exits.background { extra["bg_" + exitName(key)] = String(count) }
        if let start = exits.periodStartMs { extra["period_start"] = String(start) }
        if let end = exits.periodEndMs { extra["period_end"] = String(end) }
        return Telemetry.appEvent(label: "app_exit_daily", event: "app exits (daily, MetricKit)", reason: "app_exit_daily",
                                  atEpochMs: atEpochMs, extra: extra)
    }
}
