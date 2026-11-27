import Foundation

/// Read once per process: these do not change while the app runs.
public struct StaticDevice: Equatable, Sendable {
    /// "ios"; the OS version ("17.4"); the app's CFBundleShortVersionString, empty when missing.
    public let platform: String, osVersion: String, appVersion: String
    /// Hardware model, e.g. "Apple iPhone14,2"; never the user-given device name.
    public let model: String
    /// "Apple".
    public let brand: String
    public init(platform: String, osVersion: String, appVersion: String, model: String, brand: String) {
        self.platform = platform; self.osVersion = osVersion; self.appVersion = appVersion; self.model = model; self.brand = brand
    }
}

/// The network right now. Empty means unknown.
public struct NetworkSnapshot: Equatable, Sendable {
    /// wifi / 5g / 4g / 3g / 2g / cellular / ethernet / other / none.
    public var netType: String
    /// Contract values only (wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown).
    public var netTypeOs: String
    /// Not available to apps on current iOS: always empty (the Collector fills them in from the source address).
    public var carrier: String
    public var country: String
    /// "1" / "0"; empty when unknown (`VpnState`).
    public var vpn: String
    public var exitCountry: String
    /// Network flags with final keys (net_expensive, low_data_mode); iOS gives apps no radio levels.
    public var signal: [String: String]
    /// The raw `CTRadioAccessTechnology…` value(s) behind a cellular netType, for the Lab check only; never sent.
    public var radio: String
    public init(netType: String = "", netTypeOs: String = "", carrier: String = "", country: String = "", vpn: String = "",
                exitCountry: String = "", signal: [String: String] = [:], radio: String = "") {
        self.netType = netType; self.netTypeOs = netTypeOs; self.carrier = carrier; self.country = country; self.vpn = vpn
        self.exitCountry = exitCountry; self.signal = signal; self.radio = radio
    }
}

/// Route, accessory model and Bluetooth profile of the current output; empty = unknown or not applicable.
public struct AudioRoute: Equatable, Sendable {
    /// speaker / earpiece / wired / bluetooth.
    public var route: String
    /// Already passed through `DeviceInfo.deviceModel`; empty for the built-in speaker and receiver and for unrecognised accessories.
    public var device: String
    /// hfp / a2dp / le_audio, only on bluetooth.
    public var btProfile: String
    public init(route: String = "", device: String = "", btProfile: String = "") {
        self.route = route; self.device = device; self.btProfile = btProfile
    }
}

/// `net_type_os`: wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown.
public enum OsNetType {
    /// Collapses the app's own net_type vocabulary ("cellular", "other") onto the contract values.
    public static func normalize(_ value: String) -> String {
        ["wifi", "2g", "3g", "4g", "5g", "ethernet", "none"].contains(value) ? value : "unknown"
    }
}

/// The `vpn` context field ("1" on, "0" off, "" unknown) from `CFNetworkCopySystemProxySettings()`.
/// A VPN adds a tunnel interface (utun, ipsec, ppp, tap, tun) to the "__SCOPED__" proxy table; without one iOS
/// often leaves "__SCOPED__" out entirely, so readable settings without it mean off, and only unreadable
/// settings are unknown. Same values as Android (`TRANSPORT_VPN` on the active network), but not the same question:
/// iOS sees any connected tunnel even when it does not carry this app's traffic (split/per-app VPN), and offline
/// still reads "0" where Android, with no active network, reports "". Limitation, not verified on devices: if a
/// system service (e.g. iCloud Private Relay) ever lists its own utun here without a VPN, that reads as "1".
public enum VpnState {
    public static func from(proxySettings settings: [String: Any]?) -> String {
        guard let settings else { return "" }
        guard let scoped = settings["__SCOPED__"] as? [String: Any] else { return "0" }
        let tunnel = scoped.keys.contains { name in ["utun", "ipsec", "ppp", "tap", "tun"].contains { name.hasPrefix($0) } }
        return tunnel ? "1" : "0"
    }
}

public enum DeviceInfo {
    /// Accessory names are user-editable and carry the owner's name in any language and position
    /// ("小明的 AirPods", "AirPods de Juan", "AirPods Pro – Jason"). So nothing of the name is kept except a
    /// recognised model; anything else is "" and the name never leaves the device.
    // shortcut: known models only, so other accessories read as unknown; add a pattern when data shows a common one.
    public static func deviceModel(_ name: String?) -> String {
        guard let name, let match = name.range(of: modelPattern, options: .regularExpression) else { return "" }
        return String(name[match])
    }

    private static let modelPattern = [
        "AirPods(?: Pro| Max)?(?: \\d)?",
        "(?:Power)?[Bb]eats(?: (?:Studio|Solo|Fit|Flex|Pill|Pro|Buds\\+?|\\d))*",
        "Galaxy Buds\\d?\\+?(?: (?:Pro|Live|FE|\\d))*",
        "W[HF]-[0-9A-Z]{4,}",
    ].map { "(?:\($0))" }.joined(separator: "|")

    /// `AVAudioSession.Port` raw value and port name of the current output -> route, accessory model, profile.
    public static func audioRoute(port: String, name: String?) -> AudioRoute {
        switch port {
        case "Speaker": AudioRoute(route: "speaker")
        case "Receiver": AudioRoute(route: "earpiece")
        case "Headphones", "HeadsetMic", "USBAudio", "MicrophoneWired": AudioRoute(route: "wired")
        case "BluetoothHFP": AudioRoute(route: "bluetooth", device: deviceModel(name), btProfile: "hfp")
        case "BluetoothA2DPOutput": AudioRoute(route: "bluetooth", device: deviceModel(name), btProfile: "a2dp")
        case "BluetoothLE": AudioRoute(route: "bluetooth", device: deviceModel(name), btProfile: "le_audio")
        default: AudioRoute()
        }
    }

    /// The generation of the line that carries data, from `serviceCurrentRadioAccessTechnology`
    /// (service id -> `CTRadioAccessTechnology…`) and `dataServiceIdentifier`. With two SIMs (physical + eSIM)
    /// the other line may sit on a different generation, so another line is never taken for the data line:
    /// when the data line is unknown or unreported the answer is "cellular" unless every reported line agrees.
    /// `raw` is what CoreTelephony said, for the Lab check row only.
    public static func cellularRadio(radios: [String: String], dataService: String?) -> (generation: String, raw: String) {
        if let dataService, let radio = radios[dataService] { return (cellularGeneration(radio: radio), radio) }
        let reported = radios.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }
        let raw = reported.joined(separator: " / ")
        // A known data line that reports nothing says nothing about its generation, whatever the other line is on.
        if let dataService, !dataService.isEmpty { return ("cellular", raw) }
        let generations = Set(reported.map { cellularGeneration(radio: $0) })
        return (generations.count == 1 ? generations.first! : "cellular", raw)
    }

    /// A `CTRadioAccessTechnology…` constant -> generation.
    public static func cellularGeneration(radio: String?) -> String {
        guard let radio, !radio.isEmpty else { return "cellular" }
        if radio.contains("NR") { return "5g" }
        if radio.contains("LTE") { return "4g" }
        if radio.contains("GPRS") || radio.contains("Edge") || radio.hasSuffix("CDMA1x") { return "2g" }
        if ["WCDMA", "HSDPA", "HSUPA", "CDMAEVDO", "eHRPD"].contains(where: radio.contains) { return "3g" }
        return "cellular"
    }
}
