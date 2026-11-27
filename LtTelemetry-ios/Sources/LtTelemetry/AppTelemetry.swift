import Foundation
import LtDeviceInfo

// Port of lt-telemetry-android AppTelemetry.kt (DeviceState and Thermal are in LtDeviceInfo): error log and device state (lt-observability contract: app_error,
// sdk_event label=env / device_power / mic / abnormal_exit / app_start, device fields on quality_second).

/// OTLP severityText. Everything that is not an app_error stays INFO.
public enum Severity {
    public static let info = "INFO", warn = "WARN", error = "ERROR", fatal = "FATAL"
}

/// `error_domain`: the contract's closed list.
public enum ErrorDomain: String, CaseIterable, Sendable {
    case appExit = "app_exit", crash, rtc, api, signaling, audio, permission, telemetry, push
}

/// One error. `code` must be stable enough to group by (`http_503`, `agora_join_failed_17`), never free
/// text; `detail` is free text and is scrubbed before it leaves the device. `fatal` means the process or
/// the call ended because of it.
public struct AppError: Equatable, Sendable {
    public var domain: ErrorDomain
    public var code: String
    public var detail: String
    public var fatal: Bool
    public var severity: String
    /// The Sentry event behind a crash (32 hex), sent as `sentry_event_id`; empty = unknown, not sent.
    public var sentryEventId: String
    public init(_ domain: ErrorDomain, _ code: String, detail: String = "", fatal: Bool = false, severity: String? = nil, sentryEventId: String = "") {
        self.domain = domain; self.code = code; self.detail = detail; self.fatal = fatal
        self.severity = severity ?? (domain == .appExit ? Severity.fatal : Severity.error)
        self.sentryEventId = sentryEventId
    }
}

/// Thrown by relay clients for an HTTP answer that is not a success; the message is the user-facing text.
public struct RelayHttpError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

/// A failure that already knows its app_error (e.g. an Agora join refused with a code).
public struct AppErrorFailure: LocalizedError, Sendable {
    public let error: AppError
    public let message: String
    public init(_ error: AppError, message: String) { self.error = error; self.message = message }
    public var errorDescription: String? { message }
}

/// Relay API failures → `error_code` (domain api).
public enum ApiErrors {
    /// -1 = timed out, 0 = no answer (network), anything else the HTTP status.
    public static func status(_ status: Int) -> String {
        switch status { case -1: "http_timeout"; case 0: "http_network"; default: "http_\(status)" }
    }
    /// Nil when `error` is not an API failure (a programming or validation error).
    public static func code(_ error: any Error) -> String? {
        if let http = error as? RelayHttpError { return status(http.status) }
        if let url = error as? URLError { return url.code == .timedOut ? "http_timeout" : "http_network" }
        return nil
    }
    public static func error(_ error: any Error, _ what: String) -> AppError? {
        code(error).map { AppError(.api, $0, detail: what) }
    }
}

/// Signaling WebSocket failures (domain signaling).
public enum SignalingErrors {
    /// Close codes that end the call: the relay refused the ticket or the same user joined elsewhere.
    private static let terminal: Set<Int> = [4401, 4000]
    /// Nil for a normal close. Anything else reconnects on its own (WARN) unless the relay refused us.
    public static func closed(_ code: Int) -> AppError? {
        if code == 1000 { return nil }
        let end = terminal.contains(code)
        return AppError(.signaling, "ws_close_\(code)", fatal: end, severity: end ? Severity.error : Severity.warn)
    }
    public static func connectFailed() -> AppError { AppError(.signaling, "ws_connect_failed", severity: Severity.warn) }
}

/// `label=mic` reasons (contract enum).
public enum MicEvent: String, CaseIterable, Sendable {
    case permissionDenied = "permission_denied", silenced, unsilenced, focusLost = "focus_lost", focusGained = "focus_gained"
    case interruptedByCall = "interrupted_by_call", mediaReset = "media_reset", silentCapture = "silent_capture"
    public var reason: String { rawValue }
    public var event: String {
        switch self {
        case .permissionDenied: "microphone permission denied"
        case .silenced: "microphone silenced by the system"
        case .unsilenced: "microphone no longer silenced"
        case .focusLost: "audio focus lost"
        case .focusGained: "audio focus gained"
        case .interruptedByCall: "audio interrupted by another call"
        case .mediaReset: "media services were reset"
        case .silentCapture: "microphone captures only silence"
        }
    }
}

/// iOS audio session interruptions → `label=mic`. Only a real other call (CallKit's call observer sees one that is
/// not ours) is `interrupted_by_call`; Siri, alarms and `appWasSuspended` send no mic reason of their own (the
/// interruption still shows as `audio_session` and, while it lasts, as mic_silenced / `silenced`).
public enum MicInterruption {
    /// `reason` is the name IOSDeviceInfo gives AVAudioSession.InterruptionReason (default, builtInMicMuted, …).
    public static func event(began: Bool, reason: String, otherCallActive: Bool) -> MicEvent? {
        began && otherCallActive && reason == "default" ? .interruptedByCall : nil
    }
}

/// One `sdk_event` the controller should send for a device change.
public struct DeviceChange: Equatable, Sendable {
    public let label: String, reason: String, event: String
}

/// Turns the once-a-second `DeviceState` into `device_power` and `mic` events, only on a change,
/// and spots a microphone that sends only silence. One instance per call session.
public struct DeviceWatch: Sendable {
    /// D5: conservative, so a user who simply says nothing is not reported.
    public static let silentCaptureSeconds = 10
    public static let batteryThresholds = [20, 10, 5]
    private let silentSeconds: Int
    private var last = DeviceState()
    private var started = false
    private var batteryKnown = false
    private var batteryFired = Set<Int>()
    private var silentRun = 0
    private var silentReported = false
    public init(silentSeconds: Int = DeviceWatch.silentCaptureSeconds) { self.silentSeconds = silentSeconds }

    public mutating func observe(_ context: TelemetryContext) -> [DeviceChange] {
        let now = context.device
        let before = last
        // Keep the last known value of each field: a second the platform could not read is not a change.
        last = DeviceState(batteryPct: now.batteryPct ?? before.batteryPct, powerSave: now.powerSave ?? before.powerSave,
                           thermal: now.thermal ?? before.thermal, doze: now.doze ?? before.doze,
                           micSilenced: now.micSilenced ?? before.micSilenced, phoneCall: now.phoneCall ?? before.phoneCall)
        // The call's env snapshot describes the start: thresholds already crossed at the first known reading are not news.
        if !batteryKnown, let pct = now.batteryPct {
            batteryKnown = true
            for t in Self.batteryThresholds where pct < t { batteryFired.insert(t) }
        }
        if !started { started = true; return [] }
        var out: [DeviceChange] = []
        func power(_ reason: String, _ event: String) { out.append(DeviceChange(label: "device_power", reason: reason, event: event)) }
        func mic(_ e: MicEvent) { out.append(DeviceChange(label: "mic", reason: e.reason, event: e.event)) }
        if let n = now.powerSave, let b = before.powerSave, n != b { power(n ? "power_save_on" : "power_save_off", "power save \(n ? "on" : "off")") }
        if let n = now.thermal, let b = before.thermal, n != b { power("thermal_\(Thermal.name(n))", "thermal \(Thermal.name(b)) -> \(Thermal.name(n))") }
        if let pct = now.batteryPct {
            for t in Self.batteryThresholds where pct < t && batteryFired.insert(t).inserted { power("battery_low_\(t)", "battery below \(t)%") }
        }
        if let n = now.doze, let b = before.doze, n != b { power(n ? "doze_on" : "doze_off", "doze \(n ? "on" : "off")") }
        if let n = now.micSilenced, let b = before.micSilenced, n != b { mic(n ? .silenced : .unsilenced) }
        if now.phoneCall == true && before.phoneCall == false { mic(.interruptedByCall) }
        return out
    }

    /// True once when the microphone volume (Agora `agora_mic_volume`) has been 0 for `silentSeconds` samples
    /// in a row while the user has not muted and audio is being sent. Unknown volume never counts.
    public mutating func silentCapture(_ metrics: AudioMetrics?, muted: Bool) -> Bool {
        let volume = metrics?.extra["agora_mic_volume"].flatMap { Int($0) }
        let sending = (metrics?.sendKbps ?? 0) > 0
        guard let volume, volume == 0, !muted, sending else {
            silentRun = 0
            if let volume, volume > 0 { silentReported = false }
            return false
        }
        silentRun += 1
        if silentRun >= silentSeconds && !silentReported { silentReported = true; return true }
        return false
    }
}

/// Per call: the first occurrence of a code is sent at once, the total for codes seen again at the end.
public struct AppErrorTally: Sendable {
    private var order: [String] = []
    private var seen: [String: (error: AppError, count: Int)] = [:]
    public init() {}
    public mutating func record(_ error: AppError) -> Int {
        if seen[error.code] == nil { order.append(error.code); seen[error.code] = (error, 0) }
        seen[error.code]!.count += 1
        return seen[error.code]!.count
    }
    public func totals() -> [(error: AppError, count: Int)] { order.compactMap { seen[$0] }.filter { $0.count > 1 } }
    public mutating func clear() { order.removeAll(); seen.removeAll() }
}

/// Written to disk while a call runs and removed when it ends; still there at launch = the process was killed in a call.
public struct CallMarker: Equatable, Codable, Sendable {
    public var callId: String, channel: String, user: String, engine: String, sdkVersion: String, startedAtMs: Int64
    public init(callId: String, channel: String, user: String, engine: String, sdkVersion: String, startedAtMs: Int64) {
        self.callId = callId; self.channel = channel; self.user = user; self.engine = engine; self.sdkVersion = sdkVersion
        self.startedAtMs = startedAtMs
    }
    public func encode() -> String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "" }
    public static func decode(_ text: String?) -> CallMarker? {
        guard let data = text?.data(using: .utf8), let marker = try? JSONDecoder().decode(CallMarker.self, from: data),
              !marker.callId.isEmpty else { return nil }
        return marker
    }
}

