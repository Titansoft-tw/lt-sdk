import Foundation
import Testing
@testable import LtTelemetry

// Port of lt-call-demo CallSetupTest.kt.
struct CallSetupTests {
    private let leg = TelemetryLeg(callId: "", channel: "room-1", user: "1001", engine: "agora", sdkVersion: "agora-4.6.0")

    @Test func callSetupRecordFollowsTheContract() {
        let record = Telemetry.callSetup(leg, .peerAudioStarted, detail: "state=STARTING reason=REMOTE_UNMUTED", atEpochMs: 42)
        #expect(record.body == "sdk_event")
        #expect(record.atEpochMs == 42)
        #expect(record.attributes["label"] == "call_setup")
        #expect(record.attributes["reason"] == "peer_audio_started")
        #expect(record.attributes["detail"] == "state=STARTING reason=REMOTE_UNMUTED")
        #expect(record.attributes["channel"] == "room-1")
        #expect(record.attributes["sdk_version"] == "agora-4.6.0")
        #expect(Telemetry.callSetup(leg, .joined, detail: "", atEpochMs: 0).attributes["detail"] == nil)
        #expect(Telemetry.callSetup(leg, .joined, detail: String(repeating: "x", count: 500), atEpochMs: 0).attributes["detail"]?.count == 240)
        #expect(SetupStage.allCases.map(\.rawValue) == ["dial", "push_received", "ringing", "accept", "token_ok", "join_start", "joined",
                                                         "join_failed", "peer_joined", "peer_audio_started", "first_audio", "app_woken", "callkit_reported"])
    }

    @Test func aLabRunKeepsItsTagsAlongsideAManualTestScenario() {
        // A Lab run (test_run_id / case_id) and the manual 測試情境編號 (test_scenario) are separate attributes;
        // stamping only fills in call_id and test_scenario, so both survive on the same record.
        var lab = leg
        lab.lab = LabTag(runId: "r1", caseId: "SMK-01", role: "A", group: 2)
        lab.region = "tw"
        let stamped = Telemetry.stamp(Telemetry.callSetup(lab, .joined, detail: "", atEpochMs: 0), callId: "abc", testScenario: "08-r2").attributes
        #expect(stamped["call_id"] == "abc")
        #expect(stamped["test_scenario"] == "08-r2")
        #expect(stamped["test_run_id"] == "r1")
        #expect(stamped["case_id"] == "SMK-01")
        #expect(stamped["test_role"] == "A")
        #expect(stamped["test_group"] == "2")
        #expect(stamped["server_region"] == "tw")
    }

    @Test func stampSetsTheFinalCallIdAndTheScenarioOnlyWhenSet() {
        let record = Telemetry.callSetup(leg, .joined, detail: "", atEpochMs: 0)
        #expect(Telemetry.stamp(record, callId: "abc", testScenario: "").attributes["call_id"] == "abc")
        #expect(Telemetry.stamp(record, callId: "abc", testScenario: "").attributes["test_scenario"] == nil)
        #expect(Telemetry.stamp(record, callId: "abc", testScenario: "08-r2").attributes["test_scenario"] == "08-r2")
    }

    @Test func qualitySecondCarriesBothNetworkOpinions() {
        let a = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0,
                                        context: TelemetryContext(netType: "cellular", netTypeOs: "5g", netTypeSdk: "3g")).attributes
        #expect(a["net_type"] == "cellular") // Unchanged.
        #expect(a["net_type_os"] == "5g")
        #expect(a["net_type_sdk"] == "3g")
        let none = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 0, context: TelemetryContext(netType: "wifi", netTypeOs: "wifi")).attributes
        #expect(none["net_type_sdk"] == nil) // The engine reports none.
    }

    @Test func sdkVersionComesFromTheRecordAndIsLeftOutWithoutOne() throws {
        let device = StaticDevice(platform: "ios", osVersion: "27.2", appVersion: "0.1.0", model: "", brand: "")
        func text(_ r: TelemetryRecord) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: Telemetry.logsJson([r], device: device, serviceName: "lt-call-demo")), as: UTF8.self)
        }
        #expect(try text(Telemetry.callSetup(leg, .joined, detail: "", atEpochMs: 0)).contains("agora-4.6.0"))
        // app_start has no engine: no blank sdk_version any more (plan section 11, known differences).
        #expect(try !text(Telemetry.appStart(atEpochMs: 1)).contains("sdk_version"))
    }

    @Test func agoraCodesReadAsNames() {
        #expect(AgoraCodes.connection(5, 4) == "state=FAILED reason=JOIN_FAILED")
        #expect(AgoraCodes.connection(2, 11) == "state=CONNECTING reason=SETTING_PROXY_SERVER")
        #expect(AgoraCodes.connectionReason(99) == "REASON_99")
        #expect(AgoraCodes.remoteAudioState(1) == "STARTING")
        #expect(AgoraCodes.remoteAudioReason(6) == "REMOTE_UNMUTED")
        #expect((-1...6).map(AgoraCodes.netType) == ["unknown", "none", "ethernet", "wifi", "2g", "3g", "4g", "5g"])
    }

}
