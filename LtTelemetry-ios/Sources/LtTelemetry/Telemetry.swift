import Foundation
// The SDK builds on LtDeviceInfo (DeviceState, StaticDevice, snapshots), so an app importing LtTelemetry gets those too.
@_exported import LtDeviceInfo

// Port of lt-telemetry-android Telemetry.kt.

/// Live telemetry for lt-observability: OTLP/HTTP JSON log records posted to an OpenTelemetry
/// Collector (`POST {base}/v1/logs`). The record body is the message type and every value travels
/// as a string attribute; the platform's ClickHouse views cast them (see lt-observability
/// docs/ARCHITECTURE.md, "遙測契約"). Carries no credentials. Lab path traces carry the public addresses of routers and of our own servers, never the phone's own network.
public struct TelemetryRecord: Equatable, Sendable {
    public let body: String
    public let atEpochMs: Int64
    public let attributes: [String: String]
    /// OTLP severityText: INFO for everything except app_error (`Severity`).
    public let severity: String
    public init(body: String, atEpochMs: Int64, attributes: [String: String], severity: String = Severity.info) {
        self.body = body; self.atEpochMs = atEpochMs; self.attributes = attributes; self.severity = severity
    }
}

/// Identifies one leg of one call. Both legs must send the same `callId` to be joined.
public struct TelemetryLeg: Equatable, Sendable {
    public var callId: String
    public var channel: String
    public var user: String
    public var peer: String
    public var engine: String
    public var role: String?
    /// Self-hosted LiveKit region the call went through; empty for other engines.
    public var region: String
    public var lab: LabTag?
    /// The engine's SDK, e.g. "agora-4.6.0"; overrides the device-wide value.
    public var sdkVersion: String
    /// Connectivity experiments in effect (`Telemetry.connectivity`); empty with the defaults.
    public var extra: [String: String]
    public init(callId: String, channel: String, user: String, peer: String = "", engine: String, role: String? = nil, region: String = "",
                lab: LabTag? = nil, sdkVersion: String = "", extra: [String: String] = [:]) {
        self.callId = callId; self.channel = channel; self.user = user; self.peer = peer; self.engine = engine; self.role = role
        self.region = region; self.lab = lab; self.sdkVersion = sdkVersion; self.extra = extra
    }
}

/// What the device is on right now, read once a second. Empty means unknown. `audioDevice` must
/// already be passed through `DeviceInfo.deviceModel`: accessory names often carry the owner's name.
public struct TelemetryContext: Equatable, Sendable {
    public var netType: String      // wifi / 5g / 4g / 3g / 2g / cellular / ethernet / other / none
    public var carrier: String
    public var country: String
    public var audioRoute: String   // speaker / earpiece / wired / bluetooth
    public var audioDevice: String
    public var btProfile: String    // hfp / a2dp / le_audio
    public var vpn: String          // "1" / "0"; empty when unknown
    /// Contract values only (wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown): what the OS says.
    public var netTypeOs: String
    /// What the media SDK says (Agora networkTypeChanged); empty when the engine reports none.
    public var netTypeSdk: String
    /// Country the relay (via Cloudflare) sees this phone's traffic exit from: the VPN exit when one is on.
    public var exitCountry: String
    /// Network flags with final keys (net_expensive, low_data_mode); iOS gives apps no radio levels.
    public var signal: [String: String]
    /// iOS: the raw `CTRadioAccessTechnology…` value(s) behind a cellular netType, shown in the Lab check only; never sent.
    public var radio: String
    /// Battery, power save, thermal and microphone state; unknown fields stay nil and are not sent.
    public var device: DeviceState
    public init(netType: String = "", carrier: String = "", country: String = "",
                audioRoute: String = "", audioDevice: String = "", btProfile: String = "", vpn: String = "",
                netTypeOs: String = "", netTypeSdk: String = "", exitCountry: String = "", signal: [String: String] = [:], radio: String = "",
                device: DeviceState = DeviceState()) {
        self.device = device
        self.netType = netType; self.carrier = carrier; self.country = country
        self.audioRoute = audioRoute; self.audioDevice = audioDevice; self.btProfile = btProfile; self.vpn = vpn
        self.netTypeOs = netTypeOs; self.netTypeSdk = netTypeSdk; self.exitCountry = exitCountry; self.signal = signal
        self.radio = radio
    }
    /// From LtDeviceInfo's readers; `netTypeSdk` is what the media engine says (empty when it reports none).
    public init(_ net: NetworkSnapshot, _ route: AudioRoute, _ device: DeviceState, netTypeSdk: String = "") {
        self.init(netType: net.netType, carrier: net.carrier, country: net.country, audioRoute: route.route, audioDevice: route.device,
                  btProfile: route.btProfile, vpn: net.vpn, netTypeOs: net.netTypeOs, netTypeSdk: netTypeSdk, exitCountry: net.exitCountry,
                  signal: net.signal, radio: net.radio, device: device)
    }
    public var route: [String] { [audioRoute, audioDevice, btProfile] }
}

/// A Lab run's identity, carried on every record of the run.
public struct LabTag: Equatable, Sendable {
    public var runId: String
    public var caseId: String
    public var role: String
    public var group: Int
    /// False when the tester started although the environment check failed.
    public var envOk: Bool
    public init(runId: String, caseId: String, role: String, group: Int = 0, envOk: Bool = true) {
        self.runId = runId; self.caseId = caseId; self.role = role; self.group = group; self.envOk = envOk
    }
}

/// What telemetry sends from one per-second engine sample. Nil means unavailable, never a measured zero.
public struct AudioMetrics: Equatable, Sendable {
    public var lossPct: Double?
    public var jitterMs: Double?
    public var rttMs: Double?
    public var receiveKbps: Double?
    public var sendKbps: Double?
    public var endToEndMs: Double?
    public var jitterBufferMs: Double?
    public var concealPct: Double?
    public var mos: Double?
    public var `protocol`: String?
    public var candidateType: String?
    public var relayProtocol: String?
    public var codec: String?
    /// Uplink loss as the other side reports it back (RTCP receiver reports / Agora local stats).
    public var sendLossPct: Double?
    /// Share of time the received audio was frozen (Agora only).
    public var freezePct: Double?
    /// Engine-specific measurements sent as they are (keys namespaced: agora_*, rtc_*). Never addresses.
    public var extra: [String: String]
    public init(lossPct: Double? = nil, jitterMs: Double? = nil, rttMs: Double? = nil, receiveKbps: Double? = nil,
                sendKbps: Double? = nil, endToEndMs: Double? = nil, jitterBufferMs: Double? = nil, concealPct: Double? = nil,
                mos: Double? = nil, protocol: String? = nil, candidateType: String? = nil, relayProtocol: String? = nil,
                codec: String? = nil, sendLossPct: Double? = nil, freezePct: Double? = nil, extra: [String: String] = [:]) {
        self.lossPct = lossPct; self.jitterMs = jitterMs; self.rttMs = rttMs; self.receiveKbps = receiveKbps
        self.sendKbps = sendKbps; self.endToEndMs = endToEndMs; self.jitterBufferMs = jitterBufferMs; self.concealPct = concealPct
        self.mos = mos; self.protocol = `protocol`; self.candidateType = candidateType; self.relayProtocol = relayProtocol
        self.codec = codec; self.sendLossPct = sendLossPct; self.freezePct = freezePct; self.extra = extra
    }
}

public enum Telemetry {
    public static let qualitySecond = "quality_second"
    public static let sdkEvent = "sdk_event"
    public static let appErrorBody = "app_error"

    public static let callSetupLabel = "call_setup"
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The platform stores leg ids as UInt32, so "001234" is sent as "1234"; non-numeric ids pass through.
    static func uid(_ id: String) -> String {
        if let n = Int64(id), n >= 0 { String(n) } else { id }
    }

    private static func identity(_ leg: TelemetryLeg) -> [String: String] {
        var a = ["call_id": leg.callId, "channel": leg.channel, "leg_uid": uid(leg.user), "engine": leg.engine]
        if !leg.peer.isEmpty { a["peer_uid"] = uid(leg.peer) }
        if let role = leg.role { a["role"] = role }
        if !leg.region.isEmpty { a["server_region"] = leg.region }
        if let lab = leg.lab {
            a["test_run_id"] = lab.runId; a["case_id"] = lab.caseId; a["test_role"] = lab.role
            if lab.group > 0 { a["test_group"] = String(lab.group) }
            if !lab.envOk { a["env_ok"] = "0" }
        }
        if !leg.sdkVersion.isEmpty { a["sdk_version"] = leg.sdkVersion }
        a.merge(leg.extra) { _, extra in extra }
        return a
    }

    /// One per-second sample. An unmeasured metric is left out rather than sent as zero. The
    /// platform's integer columns reject decimals, so millisecond values are rounded here.
    public static func qualitySecond(_ leg: TelemetryLeg, _ m: AudioMetrics, atEpochMs: Int64,
                                     context: TelemetryContext = TelemetryContext(), appForeground: Bool? = nil) -> TelemetryRecord {
        var a = identity(leg)
        // Device state (error log / device state phase 1): unknown is left out, so 0 always means 0.
        if let v = appForeground { a["app_fg"] = flag(v) }
        if let v = context.device.powerSave { a["power_save"] = flag(v) }
        if let v = context.device.thermal { a["thermal"] = String(v) }
        if let v = context.device.micSilenced { a["mic_silenced"] = flag(v) }
        if let v = context.device.batteryPct { a["battery_pct"] = String(v) }
        for (key, value) in [("net_type", context.netType), ("carrier", context.carrier), ("country", context.country),
                             ("audio_route", context.audioRoute), ("audio_device", context.audioDevice), ("bt_profile", context.btProfile),
                             ("vpn", context.vpn), ("net_type_os", context.netTypeOs), ("net_type_sdk", context.netTypeSdk), ("exit_country", context.exitCountry)] + context.signal.map { ($0.key, $0.value) }
        where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            a[key] = value
        }
        func decimal(_ key: String, _ value: Double?) {
            if let value, value.isFinite { a[key] = String(format: "%.2f", locale: posix, value) }
        }
        func whole(_ key: String, _ value: Double?) {
            if let value, value.isFinite { a[key] = String(Int64(max(value, 0).rounded())) }
        }
        decimal("tx_audio_kbps", m.sendKbps)
        decimal("rx_audio_kbps", m.receiveKbps)
        decimal("tx_loss_pct", m.sendLossPct)
        decimal("rx_loss_pct", m.lossPct)
        decimal("freeze_rate_pct", m.freezePct)
        whole("rtt_ms", m.rttMs)
        whole("jitter_ms", m.jitterMs)
        whole("e2e_delay_ms", m.endToEndMs)
        whole("jitter_buffer_ms", m.jitterBufferMs)
        if let v = m.protocol { a["transport"] = v.lowercased() }
        if let v = m.candidateType { a["relay"] = v == "relay" ? "1" : "0" }
        decimal("conceal_pct", m.concealPct)
        decimal("mos", m.mos)
        if let v = m.candidateType { a["candidate_type"] = v }
        if let v = m.relayProtocol { a["relay_protocol"] = v.lowercased() }
        if let v = m.codec { a["codec"] = v }
        for (key, value) in m.extra { a[key] = value }
        return TelemetryRecord(body: qualitySecond, atEpochMs: atEpochMs, attributes: a)
    }

    public static func sdkEvent(_ leg: TelemetryLeg, label: String, event: String, reason: String, atEpochMs: Int64,
                                detail: String = "", extra: [String: String] = [:]) -> TelemetryRecord {
        var a = identity(leg)
        a["label"] = label; a["event"] = event; a["reason"] = reason
        if !detail.isEmpty { a["detail"] = String(detail.prefix(240)) }
        a.merge(extra) { _, new in new }
        return TelemetryRecord(body: sdkEvent, atEpochMs: atEpochMs, attributes: a)
    }

    /// Contract item 2: one per stage per leg.
    public static func callSetup(_ leg: TelemetryLeg, _ stage: SetupStage, detail: String, atEpochMs: Int64,
                                 extra: [String: String] = [:]) -> TelemetryRecord {
        sdkEvent(leg, label: callSetupLabel, event: "call setup: \(stage.rawValue)", reason: stage.rawValue, atEpochMs: atEpochMs, detail: detail, extra: extra)
    }

    /// A session that ended before joining without an error (user cancel, standby rebuild): not a join_failed.
    public static func cancelledBeforeJoin(_ leg: TelemetryLeg, detail: String, atEpochMs: Int64) -> TelemetryRecord {
        sdkEvent(leg, label: "session", event: "session cancelled before join", reason: "cancelled", atEpochMs: atEpochMs, detail: detail)
    }

    /// Every engine connection-state change, e.g. Agora "state=CONNECTING reason=JOIN_SUCCESS" or WebRTC ICE.
    public static func connectionState(_ leg: TelemetryLeg, _ state: String, detail: String, atEpochMs: Int64) -> TelemetryRecord {
        sdkEvent(leg, label: "connection_state", event: "connection state \(state)", reason: state, atEpochMs: atEpochMs, detail: detail)
    }

    /// AVAudioSession notifications: route_changed (with the system's reason), interrupted, interruption_ended.
    public static func audioSession(_ leg: TelemetryLeg, reason: String, detail: String, atEpochMs: Int64) -> TelemetryRecord {
        sdkEvent(leg, label: "audio_session", event: "audio session \(reason)", reason: reason, atEpochMs: atEpochMs, detail: detail)
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// `app_error` (severity from `AppError.severity`). Unlike sdk_event it carries the network context itself;
    /// platform, versions, device model and brand come from `logsJson`. Without a call (`leg` nil or without an
    /// id yet) there is no call_id.
    public static func appError(_ error: AppError, stage: String, count: Int, atEpochMs: Int64, leg: TelemetryLeg? = nil,
                                context: TelemetryContext = TelemetryContext()) -> TelemetryRecord {
        var a: [String: String] = [:]
        if let leg { a = identity(leg); if leg.callId.isEmpty { a["call_id"] = nil } }
        a["error_domain"] = error.domain.rawValue
        a["error_code"] = error.code
        a["stage"] = stage
        a["fatal"] = flag(error.fatal)
        a["count"] = String(count)
        let detail = scrub(error.detail)
        if !detail.isEmpty { a["detail"] = detail }
        a["source"] = "app"
        if error.sentryEventId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil { a["sentry_event_id"] = error.sentryEventId }
        for (key, value) in [("net_type", context.netType), ("carrier", context.carrier), ("country", context.country)] where !value.isEmpty {
            a[key] = value
        }
        return TelemetryRecord(body: appErrorBody, atEpochMs: atEpochMs, attributes: a, severity: error.severity)
    }

    private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let ipv4 = try! NSRegularExpression(pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    // Full 8-group or compressed (::) IPv6 with at least one hex group, optionally with a %zone. Like the Collector's
    // rule it must start and end at a boundary, so C++ names (std::bad_alloc, Foo::Bar) and times (12:30:45) are kept.
    private static let ipv6 = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z_:.])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?|::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})(?::(?:\\d{1,3}\\.){3}\\d{1,3})?(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z_:]|\\.\\d)")
    /// Client-side scrubbing of free text (the Collector does it again): IPv4, IPv6 and email are masked, then capped at 240.
    public static func scrub(_ text: String) -> String { String(mask(text).prefix(240)) }
    /// `scrub` without the length cap (Sentry messages and breadcrumbs).
    public static func mask(_ text: String) -> String {
        func replace(_ regex: NSRegularExpression, in text: String, keep: (String) -> Bool = { _ in false }) -> String {
            let ns = text as NSString
            var out = text
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let found = ns.substring(with: m.range)
                if keep(found) { continue }
                out = (out as NSString).replacingCharacters(in: m.range, with: regex === email ? "<email>" : "<ip>")
            }
            return out
        }
        var out = replace(email, in: text)
        // IPv6 first: it takes an IPv4-mapped address (::ffff:10.0.0.1) whole.
        out = replace(ipv6, in: out)
        out = replace(ipv4, in: out)
        return out
    }

    /// Plain events without a call (app_start, mic permission): no identity, the device fields come from `logsJson`.
    public static func appEvent(label: String, event: String, reason: String, atEpochMs: Int64, detail: String = "",
                                extra: [String: String] = [:]) -> TelemetryRecord {
        var a = ["label": label, "event": event, "reason": reason]
        if !detail.isEmpty { a["detail"] = scrub(detail) }
        a.merge(extra) { _, new in new }
        return TelemetryRecord(body: sdkEvent, atEpochMs: atEpochMs, attributes: a)
    }

    /// Once per process start: the denominator for errors per session.
    public static func appStart(atEpochMs: Int64) -> TelemetryRecord {
        appEvent(label: "app_start", event: "app start", reason: "app_start", atEpochMs: atEpochMs)
    }

    /// At launch, for a call the process did not survive; identity comes from the marker written during the call.
    public static func abnormalExit(_ marker: CallMarker, exitReason: String, atEpochMs: Int64) -> TelemetryRecord {
        var a = ["call_id": marker.callId, "label": "abnormal_exit", "event": "abnormal exit", "reason": "abnormal_exit",
                 "detail": "exit_reason=\(exitReason)"]
        if !marker.channel.isEmpty { a["channel"] = marker.channel }
        if !marker.user.isEmpty { a["leg_uid"] = uid(marker.user) }
        if !marker.engine.isEmpty { a["engine"] = marker.engine }
        if !marker.sdkVersion.isEmpty { a["sdk_version"] = marker.sdkVersion }
        return TelemetryRecord(body: sdkEvent, atEpochMs: atEpochMs, attributes: a)
    }

    /// `label=env`: the phone's state when a call starts. Only fields this platform can tell are sent.
    public static func envSnapshot(_ leg: TelemetryLeg, _ state: DeviceState, brand: String, atEpochMs: Int64) -> TelemetryRecord {
        var extra: [String: String] = [:]
        if let v = state.batteryPct { extra["battery_pct"] = String(v) }
        if let v = state.charging { extra["charging"] = flag(v) }
        if let v = state.powerSave { extra["power_save"] = flag(v) }
        if let v = state.thermal { extra["thermal"] = String(v) }
        if let v = state.doze { extra["doze"] = flag(v) }
        if let v = state.batteryOptExempt { extra["battery_opt_exempt"] = flag(v) }
        if let v = state.bgRestricted { extra["bg_restricted"] = flag(v) }
        if let v = state.standbyBucket { extra["standby_bucket"] = v }
        if let v = state.micPerm { extra["mic_perm"] = v }
        if let v = state.notifPerm { extra["notif_perm"] = v }
        if let v = state.fullscreenIntentPerm { extra["fullscreen_intent_perm"] = v }
        if !brand.isEmpty { extra["device_brand"] = brand }
        return sdkEvent(leg, label: "env", event: "environment snapshot", reason: "snapshot", atEpochMs: atEpochMs, extra: extra)
    }

    /// Stamps the call's final id and the test scenario when a batch leaves the device.
    public static func stamp(_ record: TelemetryRecord, callId: String, testScenario: String) -> TelemetryRecord {
        var a = record.attributes
        a["call_id"] = callId
        if !testScenario.isEmpty { a["test_scenario"] = testScenario }
        return TelemetryRecord(body: record.body, atEpochMs: record.atEpochMs, attributes: a, severity: record.severity)
    }

    public static func netChanged(_ leg: TelemetryLeg, from: String, to: String, atEpochMs: Int64) -> TelemetryRecord {
        sdkEvent(leg, label: "network", event: "network changed \(from) -> \(to)", reason: "net_changed", atEpochMs: atEpochMs)
    }

    public static func reconnecting(_ leg: TelemetryLeg, active: Bool, netType: String, atEpochMs: Int64) -> TelemetryRecord {
        sdkEvent(leg, label: "network", event: active ? "reconnecting" : "reconnected\(netType.isEmpty ? "" : " on \(netType)")",
                 reason: active ? "reconnecting" : "reconnected", atEpochMs: atEpochMs)
    }

    public static func routeChanged(_ leg: TelemetryLeg, from: TelemetryContext, to: TelemetryContext, atEpochMs: Int64) -> TelemetryRecord {
        let detail = [to.audioDevice, to.btProfile].filter { !$0.isEmpty }.joined(separator: ", ")
        let event = "audio route changed \(from.audioRoute.isEmpty ? "unknown" : from.audioRoute) -> "
            + "\(to.audioRoute.isEmpty ? "unknown" : to.audioRoute)" + (detail.isEmpty ? "" : " (\(detail))")
        return sdkEvent(leg, label: "audio_route", event: event, reason: "route_changed", atEpochMs: atEpochMs)
    }

    /// Last line of defence (docs/e2ee.md): an attribute whose name looks like key material, a
    /// credential or the E2EE safety code is dropped at encoding time, whoever added it.
    private static let secret = try! NSRegularExpression(pattern: Contract.secretPattern)
    public static func isSecretAttribute(_ name: String) -> Bool {
        secret.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }

    /// OTLP/HTTP JSON for `/v1/logs`. Device fields go on every record because the views read log attributes;
    /// sdk_version comes from the record (the engine that produced it) and is left out when there is none.
    /// `observedEpochMs`: when the batch leaves the device (OTLP observedTimeUnixNano); `timeUnixNano` stays when the record
    /// was made, so a record delivered late (after an outage or a crash) shows how late it was.
    public static func logsJson(_ records: [TelemetryRecord], device: StaticDevice, serviceName: String,
                                observedEpochMs: Int64? = nil) -> [String: Any] {
        func string(_ value: String) -> [String: Any] { ["stringValue": value] }
        var common = ["platform": device.platform, "os_version": device.osVersion, "app_version": device.appVersion]
        if !device.model.isEmpty { common["device_model"] = device.model }
        if !device.brand.isEmpty { common["device_brand"] = device.brand }
        let logs: [[String: Any]] = records.map { record in
            let attributes = record.attributes.merging(common) { own, _ in own }.filter { !isSecretAttribute($0.key) }
            var log: [String: Any] = [
                "timeUnixNano": "\(record.atEpochMs)000000", "severityText": record.severity, "body": string(record.body),
                "attributes": attributes.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": string($0.value)] as [String: Any] },
            ]
            if let observedEpochMs { log["observedTimeUnixNano"] = "\(observedEpochMs)000000" }
            return log
        }
        return ["resourceLogs": [[
            "resource": ["attributes": [["key": "service.name", "value": string(serviceName)]]],
            "scopeLogs": [["logRecords": logs]],
        ] as [String: Any]]]
    }
}
