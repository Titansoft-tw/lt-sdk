#if canImport(UIKit) && os(iOS)
import AVFAudio
import CallKit
import CFNetwork
import CoreTelephony
import Foundation
import Network
import UIKit
import UserNotifications

/// AVAudioSession notifications, already turned into names. `IOSDeviceInfo.onAudioSession` receives them on the main actor.
public enum AudioSessionEvent: Equatable, Sendable {
    /// An interruption began or ended. `reason` is the InterruptionReason name (default, builtInMicMuted,
    /// routeDisconnected, appWasSuspended, raw_<n>, none); `otherCallActive` = a call that is not the app's own
    /// CallKit call is up (a phone call or another VoIP app). `detail` is ready for `audio_session`.
    case interruption(began: Bool, reason: String, otherCallActive: Bool, detail: String)
    /// The route changed; `detail` has the system's reason, the route and the Bluetooth profile, never accessory names.
    case routeChanged(detail: String)
    /// The media server restarted: every audio object is gone and the session must be set up again.
    case mediaServicesReset
}

/// Reads the device, network, audio route and power state on iOS. Only reads: sends nothing and needs no telemetry.
/// Every reader is cheap enough to call once a second; unknown values are empty or nil.
@MainActor public final class IOSDeviceInfo {
    /// Asked once per network (type + VPN) where the traffic exits (lt-call-demo: the relay's `GET /v1/whoami`).
    private let exitCountryLookup: (@Sendable () async -> String?)?
    /// The app's own CallKit call, so it is not taken for "another call".
    private let ownCallUUID: @MainActor () -> UUID?
    /// Audio session interruptions, route changes and media resets.
    public var onAudioSession: (AudioSessionEvent) -> Void = { _ in }

    private var interrupted = false
    private var notificationPermission: String?
    private let radios = CellularRadioSource()
    private let callObserver = CXCallObserver()
    private lazy var pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.tswork.lt.deviceinfo.path"))
        return monitor
    }()

    public init(exitCountryLookup: (@Sendable () async -> String?)? = nil, ownCallUUID: @escaping @MainActor () -> UUID? = { nil }) {
        self.exitCountryLookup = exitCountryLookup
        self.ownCallUUID = ownCallUUID
        UIDevice.current.isBatteryMonitoringEnabled = true
        observeAudioSession()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNotificationPermission() }
        }
        refreshNotificationPermission()
    }

    public let staticDevice: StaticDevice = {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return StaticDevice(platform: "ios", osVersion: UIDevice.current.systemVersion,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                            model: "Apple " + machine, brand: "Apple")
    }()

    /// A background wake (VoIP push, audio) has no active scene: `.active` is the only foreground state.
    public func isForeground() -> Bool? { UIApplication.shared.applicationState == .active }

    /// iOS does not say why the previous process ended: always "unknown" (MetricKit has daily totals instead).
    public func exitReason(sinceEpochMs: Int64) -> String { "unknown" }

    /// `wake_ms`: milliseconds since the kernel started this process (sysctl KERN_PROC_PID p_starttime).
    public func processUptimeMs() -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startMs = Int64(start.tv_sec) * 1_000 + Int64(start.tv_usec) / 1_000
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        return now >= startMs ? now - startMs : nil
    }

    // MARK: Device state

    /// The once-a-second state: battery, Low Power Mode, thermal state, an interruption in progress.
    public func deviceState() -> DeviceState {
        let level = UIDevice.current.batteryLevel // -1 when unknown (simulator, monitoring off)
        let battery = UIDevice.current.batteryState
        return DeviceState(batteryPct: level >= 0 ? Int((level * 100).rounded()) : nil,
                           charging: battery == .unknown ? nil : (battery == .charging || battery == .full),
                           powerSave: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermal: Thermal.ios(ProcessInfo.processInfo.thermalState.rawValue),
                           micSilenced: interrupted)
    }

    /// The full state for the call's `label=env` snapshot: adds the microphone and notification permissions.
    public func deviceSnapshot() -> DeviceState {
        var state = deviceState()
        state.micPerm = switch AVAudioApplication.shared.recordPermission {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        @unknown default: nil
        }
        state.notifPerm = notificationPermission
        return state
    }

    private func refreshNotificationPermission() {
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self.notificationPermission = switch status {
            case .authorized, .provisional, .ephemeral: "granted"
            case .denied: "denied"
            case .notDetermined: "undetermined"
            @unknown default: nil
            }
        }
    }

    // MARK: Network

    /// Network type (the data line on dual SIM), VPN, exit country and the expensive / low data flags.
    public func network() -> NetworkSnapshot {
        let path = pathMonitor.currentPath
        let net: String
        var radio = ""
        if path.status != .satisfied { net = "none" }
        // Under a VPN the path may only report the tunnel (.other); the physical link is then among the interfaces.
        else if path.usesInterfaceType(.wifi) || (path.usesInterfaceType(.other) && path.availableInterfaces.contains { $0.type == .wifi }) { net = "wifi" }
        else if path.usesInterfaceType(.wiredEthernet) { net = "ethernet" }
        else if path.usesInterfaceType(.cellular) || (path.usesInterfaceType(.other) && path.availableInterfaces.contains { $0.type == .cellular }) {
            // Carrier name and country are no longer available to apps on current iOS, so they stay empty.
            let telephony = radios.current()
            let cell = DeviceInfo.cellularRadio(radios: telephony.serviceCurrentRadioAccessTechnology ?? [:],
                                                dataService: telephony.dataServiceIdentifier)
            net = cell.generation; radio = cell.raw
        } else { net = "other" }
        let vpn = VpnState.from(proxySettings: CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
        refreshExitCountry("\(net)|\(vpn)")
        let flags = ["net_expensive": path.isExpensive ? "1" : "0", "low_data_mode": path.isConstrained ? "1" : "0"]
        return NetworkSnapshot(netType: net, netTypeOs: OsNetType.normalize(net), vpn: vpn, exitCountry: exitCountry, signal: flags, radio: radio)
    }

    private var exitCountry = ""
    private var exitKey: String?
    private func refreshExitCountry(_ key: String) {
        guard key != exitKey else { return }
        exitKey = key; exitCountry = ""
        guard let lookup = exitCountryLookup else { return }
        Task { @MainActor in
            if let country = await lookup(), self.exitKey == key { self.exitCountry = country }
        }
    }

    // MARK: Audio

    /// The current output's route, accessory model (owner's name removed) and Bluetooth profile.
    public func audioRoute() -> AudioRoute {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return AudioRoute() }
        return DeviceInfo.audioRoute(port: output.portType.rawValue, name: output.portName)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let began = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
            let reason = Self.interruptionReason((info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init))
            let resume = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            let detail = began ? "type=began reason=\(reason)" : "type=ended should_resume=\(resume)"
            MainActor.assumeIsolated {
                guard let self else { return }
                // mic_silenced follows the interruption.
                self.interrupted = AudioInterruption.silences(began: began, reason: reason)
                self.onAudioSession(.interruption(began: began, reason: reason, otherCallActive: self.otherCallActive(), detail: detail))
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init).map(Self.routeChangeReason) ?? "unknown"
            // Route and Bluetooth profile only: accessory names can carry the owner's name.
            let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
            let route = output.map { DeviceInfo.audioRoute(port: $0.portType.rawValue, name: nil) } ?? AudioRoute()
            let detail = "reason=\(reason) route=\(route.route.isEmpty ? "unknown" : route.route)" + (route.btProfile.isEmpty ? "" : " profile=\(route.btProfile)")
            MainActor.assumeIsolated { self?.onAudioSession(.routeChanged(detail: detail)) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupted = false
                self?.onAudioSession(.mediaServicesReset)
            }
        }
    }

    /// A call (phone or another VoIP app) that is not this app's own CallKit call.
    private func otherCallActive() -> Bool {
        let ours = ownCallUUID()
        return callObserver.calls.contains { !$0.hasEnded && $0.uuid != ours }
    }

    nonisolated private static func interruptionReason(_ reason: AVAudioSession.InterruptionReason?) -> String {
        switch reason {
        case .default?: "default"
        case .builtInMicMuted?: "builtInMicMuted"
        case .routeDisconnected?: "routeDisconnected"
        case .appWasSuspended?: "appWasSuspended"
        case let other?: "raw_\(other.rawValue)"
        case nil: "none"
        }
    }
    nonisolated private static func routeChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        default: "unknown"
        }
    }
}

/// A `CTTelephonyNetworkInfo` keeps its own copy of the radio values, updated by CoreTelephony pushes. A push that
/// lands while the app is suspended is lost, and a long-lived instance then keeps reporting the old radio. So the
/// instance is replaced whenever the app becomes active, and once it is older than `maxAge`.
@MainActor private final class CellularRadioSource {
    private static let maxAge: Duration = .seconds(5)
    private var info = CTTelephonyNetworkInfo()
    private var createdAt = ContinuousClock.now
    /// A replacement waiting to be trusted: a new instance may fill its values asynchronously, and an empty first
    /// read would turn 5g into "cellular" for a tick. It is adopted only once it reports a radio.
    private var pending: CTTelephonyNetworkInfo?

    init() {
        // Lives as long as its IOSDeviceInfo, usually the whole process.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renew() }
        }
    }

    func current() -> CTTelephonyNetworkInfo {
        if ContinuousClock.now - createdAt >= Self.maxAge { renew() }
        if let pending, !(pending.serviceCurrentRadioAccessTechnology ?? [:]).isEmpty { info = pending; self.pending = nil }
        return info
    }
    private func renew() {
        if pending == nil { pending = CTTelephonyNetworkInfo() }
        createdAt = .now
    }
}
#endif
