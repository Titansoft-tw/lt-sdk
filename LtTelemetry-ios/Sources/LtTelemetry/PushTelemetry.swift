import Foundation

// Port of lt-telemetry-android PushTelemetry.kt (AppLaunch and AppLaunchTracker are in LtDeviceInfo) (phase 2 of the error log, docs/error-device-telemetry.md「第 2 期」): the
// incoming-call push path and CallKit. iOS adds the CallKit pieces Android does not have.

/// Push and incoming-call errors (domain push / audio), with the contract's severities.
public enum PushErrors {
    /// `POST /v1/devices` answered `status`: nil on success and on 501 (push not configured on the relay: expected).
    public static func register(status: Int) -> AppError? {
        (200..<300).contains(status) || status == 501 ? nil : AppError(.push, ApiErrors.status(status), detail: "POST /v1/devices")
    }
    /// No push token to register (an empty VoIP token).
    public static func tokenUnavailable(_ detail: String) -> AppError { AppError(.push, "push_token_register_failed", detail: detail) }
    /// CallKit refused reportNewIncomingCall.
    public static func callKitReportFailed(_ detail: String) -> AppError { AppError(.push, "callkit_report_failed", detail: detail) }
    /// The call was answered but CallKit never activated the audio session (one-way silence).
    public static func callKitAudioNotActivated(afterMs: Int64) -> AppError {
        AppError(.audio, "callkit_audio_not_activated", detail: "no didActivate \(afterMs / 1_000) s after answer")
    }
}

/// `label=callkit_audio` and the 5-second rule: an answered CallKit call whose audio session CallKit has not
/// activated `timeoutMs` after the answer, and that is still up, is `callkit_audio_not_activated` (once).
public struct CallKitAudioWatch: Sendable {
    /// Contract decision P3: 5 seconds.
    public static let timeoutMs: Int64 = 5_000
    private var answeredAt: Int64?
    private var activated = false
    private var reported = false
    public init() {}
    public var answered: Bool { answeredAt != nil }
    public mutating func answer(atMs: Int64) { answeredAt = atMs; activated = false; reported = false }
    public mutating func activate() { activated = true }
    /// Hung up or CallKit ended the call: nothing to report any more.
    public mutating func end() { answeredAt = nil }
    /// True once, when the call is still up, not activated and `timeoutMs` have passed since the answer.
    public mutating func overdue(nowMs: Int64) -> Bool {
        guard let at = answeredAt, !activated, !reported, nowMs - at >= Self.timeoutMs else { return false }
        reported = true
        return true
    }
}
