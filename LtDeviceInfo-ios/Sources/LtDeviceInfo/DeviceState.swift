import Foundation

/// What the phone is doing, read once a second (`IOSDeviceInfo.deviceState()`) and, in full, once per call
/// (`deviceSnapshot()`). Nil = this platform cannot tell; it is then not sent (never as 0).
public struct DeviceState: Equatable, Sendable {
    public var batteryPct: Int?
    public var charging: Bool?
    public var powerSave: Bool?
    /// 0–3, see `Thermal`.
    public var thermal: Int?
    public var doze: Bool?
    public var batteryOptExempt: Bool?
    public var bgRestricted: Bool?
    public var standbyBucket: String?
    /// granted / denied / undetermined.
    public var micPerm: String?
    public var notifPerm: String?
    public var fullscreenIntentPerm: String?
    /// The system silenced the microphone (iOS: an audio session interruption is in progress).
    public var micSilenced: Bool?
    public var phoneCall: Bool?
    public init(batteryPct: Int? = nil, charging: Bool? = nil, powerSave: Bool? = nil, thermal: Int? = nil, doze: Bool? = nil,
                batteryOptExempt: Bool? = nil, bgRestricted: Bool? = nil, standbyBucket: String? = nil, micPerm: String? = nil,
                notifPerm: String? = nil, fullscreenIntentPerm: String? = nil, micSilenced: Bool? = nil, phoneCall: Bool? = nil) {
        self.batteryPct = batteryPct; self.charging = charging; self.powerSave = powerSave; self.thermal = thermal; self.doze = doze
        self.batteryOptExempt = batteryOptExempt; self.bgRestricted = bgRestricted; self.standbyBucket = standbyBucket
        self.micPerm = micPerm; self.notifPerm = notifPerm; self.fullscreenIntentPerm = fullscreenIntentPerm
        self.micSilenced = micSilenced; self.phoneCall = phoneCall
    }
}

/// Contract thermal levels: 0 nominal, 1 fair (light), 2 serious (severe), 3 critical or worse.
public enum Thermal {
    /// `ProcessInfo.ThermalState` raw value: nominal 0, fair 1, serious 2, critical 3 (already the contract's scale).
    public static func ios(_ raw: Int) -> Int? { (0...3).contains(raw) ? raw : nil }
    /// PowerManager.THERMAL_STATUS_* (Android's 7 levels), kept here so both platforms document one table.
    public static func android(_ status: Int) -> Int? {
        switch status { case 0: 0; case 1, 2: 1; case 3: 2; case 4...6: 3; default: nil }
    }
    public static func name(_ level: Int) -> String {
        switch level { case 0: "nominal"; case 1: "fair"; case 2: "serious"; default: "critical" }
    }
}

/// `app_launch` on push_received / app_woken.
public enum AppLaunch {
    public static let cold = "cold", background = "background", foreground = "foreground"
}

/// Classifies each push by the app's state when it arrived: foreground = the app is in front now; cold = the first
/// push this process handles and no scene was ever active in it (the push started the process); else background.
public struct AppLaunchTracker: Sendable {
    private var everForeground = false
    private var pushes = 0
    public init() {}
    public mutating func foreground() { everForeground = true }
    public mutating func classify(foreground: Bool?) -> String {
        let first = pushes == 0
        pushes += 1
        if foreground == true { return AppLaunch.foreground }
        return first && !everForeground ? AppLaunch.cold : AppLaunch.background
    }
}

/// AVAudioSession interruptions and the microphone.
public enum AudioInterruption {
    /// An interruption because the app was suspended is not the microphone being taken away. `reason` is the name
    /// `IOSDeviceInfo` gives AVAudioSession.InterruptionReason (default, builtInMicMuted, appWasSuspended, …).
    public static func silences(began: Bool, reason: String) -> Bool { began && reason != "appWasSuspended" }
}
