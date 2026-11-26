import Foundation

/// What one MXDiagnosticPayload held that matters here.
public struct MetricKitDiagnostics: Equatable, Sendable {
    /// MXHangDiagnostic.hangDuration, in milliseconds.
    public var hangsMs: [Int64]
    /// MXCrashDiagnostic, summarised (exception type / signal, never a stack or a path).
    public var crashes: [String]
    public init(hangsMs: [Int64] = [], crashes: [String] = []) { self.hangsMs = hangsMs; self.crashes = crashes }
}

/// MXAppExitMetric: daily totals by reason. Keys are Apple's property names (`cumulativeNormalAppExitCount`).
public struct MetricKitExits: Equatable, Sendable {
    public var foreground: [String: Int]
    public var background: [String: Int]
    public var periodStartMs: Int64?
    public var periodEndMs: Int64?
    public init(foreground: [String: Int], background: [String: Int], periodStartMs: Int64? = nil, periodEndMs: Int64? = nil) {
        self.foreground = foreground; self.background = background; self.periodStartMs = periodStartMs; self.periodEndMs = periodEndMs
    }
}

#if canImport(MetricKit) && os(iOS)
import MetricKit

/// Subscribes to MetricKit and turns its payloads into plain values (hangs, crash summaries, daily exits). Payloads
/// arrive on a background queue at most once a day; the callbacks run on the main actor. Keep the instance alive.
public final class MetricKitSource: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let onDiagnostics: @MainActor (MetricKitDiagnostics) -> Void
    private let onExits: @MainActor (MetricKitExits) -> Void

    @MainActor public init(onDiagnostics: @escaping @MainActor (MetricKitDiagnostics) -> Void,
                           onExits: @escaping @MainActor (MetricKitExits) -> Void) {
        self.onDiagnostics = onDiagnostics
        self.onExits = onExits
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit { MXMetricManager.shared.remove(self) }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        let exits = payloads.compactMap { payload -> MetricKitExits? in
            guard let metric = payload.applicationExitMetrics else { return nil }
            let fg = metric.foregroundExitData, bg = metric.backgroundExitData
            return MetricKitExits(
                foreground: [
                    "cumulativeNormalAppExitCount": fg.cumulativeNormalAppExitCount,
                    "cumulativeMemoryResourceLimitExitCount": fg.cumulativeMemoryResourceLimitExitCount,
                    "cumulativeBadAccessExitCount": fg.cumulativeBadAccessExitCount,
                    "cumulativeAbnormalExitCount": fg.cumulativeAbnormalExitCount,
                    "cumulativeIllegalInstructionExitCount": fg.cumulativeIllegalInstructionExitCount,
                    "cumulativeAppWatchdogExitCount": fg.cumulativeAppWatchdogExitCount,
                ],
                background: [
                    "cumulativeNormalAppExitCount": bg.cumulativeNormalAppExitCount,
                    "cumulativeMemoryResourceLimitExitCount": bg.cumulativeMemoryResourceLimitExitCount,
                    "cumulativeCPUResourceLimitExitCount": bg.cumulativeCPUResourceLimitExitCount,
                    "cumulativeMemoryPressureExitCount": bg.cumulativeMemoryPressureExitCount,
                    "cumulativeBadAccessExitCount": bg.cumulativeBadAccessExitCount,
                    "cumulativeAbnormalExitCount": bg.cumulativeAbnormalExitCount,
                    "cumulativeIllegalInstructionExitCount": bg.cumulativeIllegalInstructionExitCount,
                    "cumulativeAppWatchdogExitCount": bg.cumulativeAppWatchdogExitCount,
                    "cumulativeSuspendedWithLockedFileExitCount": bg.cumulativeSuspendedWithLockedFileExitCount,
                    "cumulativeBackgroundTaskAssertionTimeoutExitCount": bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                ],
                periodStartMs: Int64(payload.timeStampBegin.timeIntervalSince1970 * 1_000),
                periodEndMs: Int64(payload.timeStampEnd.timeIntervalSince1970 * 1_000))
        }
        let onExits = onExits
        Task { @MainActor in for exit in exits { onExits(exit) } }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let diagnostics = payloads.map { payload in
            MetricKitDiagnostics(
                hangsMs: (payload.hangDiagnostics ?? []).map { Int64($0.hangDuration.converted(to: .milliseconds).value.rounded()) },
                // Exception type and signal only: no call stack, no paths.
                crashes: (payload.crashDiagnostics ?? []).map { crash in
                    "exception=\(crash.exceptionType?.stringValue ?? "-") signal=\(crash.signal?.stringValue ?? "-")"
                })
        }
        let onDiagnostics = onDiagnostics
        Task { @MainActor in for d in diagnostics { onDiagnostics(d) } }
    }
}
#endif
