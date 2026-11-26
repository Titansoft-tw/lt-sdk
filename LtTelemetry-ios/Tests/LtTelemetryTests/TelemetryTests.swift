import Foundation
import Testing
@testable import LtTelemetry

// Port of lt-call-demo TelemetryTest.kt.

private let leg = TelemetryLeg(callId: "c1", channel: "room-1", user: "001234", peer: "567890", engine: "webrtc", role: "caller")

@Test func qualitySecondMapsMeasuredFieldsAndOmitsTheRest() {
    let record = Telemetry.qualitySecond(leg, AudioMetrics(lossPct: 1.234, jitterMs: 4.6, rttMs: 180.4, receiveKbps: 26,
        jitterBufferMs: 119.5, protocol: "UDP", candidateType: "relay", relayProtocol: "TCP", codec: "audio/opus"),
        atEpochMs: 1_700_000_000_123)
    let a = record.attributes
    #expect(record.body == "quality_second")
    #expect(a["call_id"] == "c1")
    #expect(a["channel"] == "room-1")
    #expect(a["leg_uid"] == "1234")
    #expect(a["peer_uid"] == "567890")
    #expect(a["engine"] == "webrtc")
    #expect(a["role"] == "caller")
    #expect(a["rx_audio_kbps"] == "26.00")
    #expect(a["rx_loss_pct"] == "1.23")
    // Integer columns on the platform: a decimal string would be stored as 0.
    #expect(a["rtt_ms"] == "180")
    #expect(a["jitter_ms"] == "5")
    #expect(a["jitter_buffer_ms"] == "120")
    #expect(a["transport"] == "udp")
    #expect(a["relay"] == "1")
    #expect(a["relay_protocol"] == "tcp")
    // Not measured on this engine: absent, never zero.
    #expect(a["tx_audio_kbps"] == nil)
    #expect(a["e2e_delay_ms"] == nil)
    #expect(a["mos"] == nil)
}

@Test func directPathIsNotRelayAndUnknownPathIsOmitted() {
    #expect(Telemetry.qualitySecond(leg, AudioMetrics(candidateType: "srflx"), atEpochMs: 0).attributes["relay"] == "0")
    #expect(Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0).attributes["relay"] == nil)
    var alone = leg
    alone.peer = ""
    #expect(Telemetry.qualitySecond(alone, AudioMetrics(), atEpochMs: 0).attributes["peer_uid"] == nil)
}

@Test func logsJsonIsOtlpWithStringValuesAndDeviceFields() throws {
    let event = Telemetry.sdkEvent(leg, label: "audio_sending", event: "the user muted \"local\" audio\n", reason: "muted",
                                   atEpochMs: 1_700_000_000_123)
    let data = try JSONSerialization.data(withJSONObject: Telemetry.logsJson([event], device: StaticDevice(platform: "ios", osVersion: "18.1", appVersion: "1.0", model: "", brand: ""), serviceName: "lt-call-demo"))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let resource = try #require((root["resourceLogs"] as? [[String: Any]])?.first)
    let service = try #require(((resource["resource"] as? [String: Any])?["attributes"] as? [[String: Any]])?.first)
    #expect(service["key"] as? String == "service.name")
    #expect((service["value"] as? [String: Any])?["stringValue"] as? String == "lt-call-demo")
    let record = try #require(((resource["scopeLogs"] as? [[String: Any]])?.first?["logRecords"] as? [[String: Any]])?.first)
    #expect(record["timeUnixNano"] as? String == "1700000000123000000")
    #expect((record["body"] as? [String: Any])?["stringValue"] as? String == "sdk_event")
    var attributes: [String: String] = [:]
    for item in try #require(record["attributes"] as? [[String: Any]]) {
        attributes[try #require(item["key"] as? String)] = try #require((item["value"] as? [String: Any])?["stringValue"] as? String)
    }
    #expect(attributes["reason"] == "muted")
    #expect(attributes["platform"] == "ios")
    #expect(attributes["os_version"] == "18.1")
    #expect(attributes["event"] == "the user muted \"local\" audio\n")
}

@Test func contextAndUplinkFieldsAreSentWhenKnown() {
    let context = TelemetryContext(netType: "5g", carrier: "CHT", country: "TW",
                                   audioRoute: "bluetooth", audioDevice: "AirPods Pro", btProfile: "hfp")
    let a = Telemetry.qualitySecond(leg, AudioMetrics(sendKbps: 31.5, sendLossPct: 2, freezePct: 4.5), atEpochMs: 0, context: context).attributes
    #expect(a["net_type"] == "5g")
    #expect(a["carrier"] == "CHT")
    #expect(a["country"] == "TW")
    #expect(a["audio_route"] == "bluetooth")
    #expect(a["audio_device"] == "AirPods Pro")
    #expect(a["bt_profile"] == "hfp")
    #expect(a["tx_audio_kbps"] == "31.50")
    #expect(a["tx_loss_pct"] == "2.00")
    #expect(a["freeze_rate_pct"] == "4.50")
    let blank = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0).attributes
    #expect(blank["net_type"] == nil)
    #expect(blank["audio_device"] == nil)
}

@Test func switchEventsFollowThePlatformContract() {
    let net = Telemetry.netChanged(leg, from: "wifi", to: "5g", atEpochMs: 0).attributes
    #expect(net["label"] == "network")
    #expect(net["reason"] == "net_changed")
    #expect(net["event"] == "network changed wifi -> 5g")
    let route = Telemetry.routeChanged(leg, from: TelemetryContext(audioRoute: "speaker"),
        to: TelemetryContext(audioRoute: "bluetooth", audioDevice: "AirPods Pro", btProfile: "hfp"), atEpochMs: 0).attributes
    #expect(route["label"] == "audio_route")
    #expect(route["reason"] == "route_changed")
    #expect(route["event"] == "audio route changed speaker -> bluetooth (AirPods Pro, hfp)")
    #expect(Telemetry.reconnecting(leg, active: false, netType: "5g", atEpochMs: 0).attributes["event"] == "reconnected on 5g")
    #expect(Telemetry.reconnecting(leg, active: true, netType: "5g", atEpochMs: 0).attributes["reason"] == "reconnecting")
}

@Test func rawRadioIsNotSent() {
    let context = TelemetryContext(netType: "4g", radio: "CTRadioAccessTechnologyLTE")
    let attributes = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0, context: context).attributes
    #expect(!attributes.values.contains { $0.contains("CTRadioAccessTechnology") })
}

@Test func serverRegionIsSentOnlyWhenKnown() {
    var onprem = leg; onprem.engine = "livekit_onprem"; onprem.region = "hk"
    #expect(Telemetry.qualitySecond(onprem, AudioMetrics(), atEpochMs: 0).attributes["server_region"] == "hk")
    #expect(Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0).attributes["server_region"] == nil)
}
