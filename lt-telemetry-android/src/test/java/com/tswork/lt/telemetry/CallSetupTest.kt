package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.*
import com.tswork.lt.telemetry.lab.*
import org.junit.Assert.*
import org.junit.Test

class CallSetupTest {
    private val leg = TelemetryLeg(callId = "", channel = "room-1", user = "1001", engine = "agora", sdkVersion = "agora-4.7.0")

    @Test fun callSetupRecordFollowsTheContract() {
        val record = Telemetry.callSetup(leg, SetupStage.PEER_AUDIO_STARTED, "state=STARTING reason=REMOTE_UNMUTED", 42)
        assertEquals("sdk_event", record.body)
        assertEquals(42, record.atEpochMs)
        assertEquals("call_setup", record.attributes["label"])
        assertEquals("peer_audio_started", record.attributes["reason"])
        assertEquals("state=STARTING reason=REMOTE_UNMUTED", record.attributes["detail"])
        assertEquals("room-1", record.attributes["channel"])
        assertEquals("agora-4.7.0", record.attributes["sdk_version"])
        assertFalse("detail" in Telemetry.callSetup(leg, SetupStage.JOINED, "", 0).attributes)
        assertEquals(240, Telemetry.callSetup(leg, SetupStage.JOINED, "x".repeat(500), 0).attributes["detail"]?.length)
        assertEquals(listOf("dial", "push_received", "ringing", "accept", "token_ok", "join_start", "joined", "join_failed",
            "peer_joined", "peer_audio_started", "first_audio", "app_woken", "callkit_reported"), SetupStage.entries.map { it.code })
    }

    @Test fun stampSetsTheFinalCallIdAndTheScenarioOnlyWhenSet() {
        val record = Telemetry.callSetup(leg, SetupStage.JOINED, "", 0)
        assertEquals("abc", Telemetry.stamp(record, "abc", "").attributes["call_id"])
        assertFalse("test_scenario" in Telemetry.stamp(record, "abc", "").attributes)
        assertEquals("08-r2", Telemetry.stamp(record, "abc", "08-r2").attributes["test_scenario"])
    }

    @Test fun aLabRunKeepsItsTagsAlongsideAManualTestScenario() {
        // A Lab run (test_run_id / case_id) and the manual 測試情境編號 (test_scenario) are separate attributes;
        // stamping only fills in call_id and test_scenario, so both survive on the same record.
        val lab = leg.copy(lab = LabTag(runId = "r1", caseId = "SMK-01", role = "A", group = 2), region = "tw")
        val stamped = Telemetry.stamp(Telemetry.callSetup(lab, SetupStage.JOINED, "", 0), "abc", "08-r2").attributes
        assertEquals("abc", stamped["call_id"])
        assertEquals("08-r2", stamped["test_scenario"])
        assertEquals("r1", stamped["test_run_id"])
        assertEquals("SMK-01", stamped["case_id"])
        assertEquals("A", stamped["test_role"])
        assertEquals("2", stamped["test_group"])
        assertEquals("tw", stamped["server_region"])
    }

    @Test fun qualitySecondCarriesBothNetworkOpinions() {
        val a = Telemetry.qualitySecond(leg, AudioMetrics(), 0, TelemetryContext(netType = "cellular", netTypeOs = "5g", netTypeSdk = "3g")).attributes
        assertEquals("cellular", a["net_type"]) // Unchanged.
        assertEquals("5g", a["net_type_os"])
        assertEquals("3g", a["net_type_sdk"])
        val none = Telemetry.qualitySecond(leg, AudioMetrics(), 0, TelemetryContext(netType = "wifi", netTypeOs = "wifi")).attributes
        assertFalse("net_type_sdk" in none) // The engine reports none.
    }

    @Test fun sdkVersionComesFromTheRecordAndIsLeftOutWithoutOne() {
        val device = StaticDevice("android", "15", "0.1.0", "", "")
        val json = Telemetry.logsJson(listOf(Telemetry.callSetup(leg, SetupStage.JOINED, "", 0)), device, "lt-call-demo")
        assertTrue(json.contains("""{"key":"sdk_version","value":{"stringValue":"agora-4.7.0"}}"""))
        // app_start has no engine: no blank sdk_version any more (plan section 11, known differences).
        assertFalse(Telemetry.logsJson(listOf(Telemetry.appStart(1)), device, "lt-call-demo").contains("sdk_version"))
    }

    @Test fun agoraCodesReadAsNames() {
        assertEquals("state=FAILED reason=JOIN_FAILED", AgoraCodes.connection(5, 4))
        assertEquals("state=CONNECTING reason=SETTING_PROXY_SERVER", AgoraCodes.connection(2, 11))
        assertEquals("REASON_99", AgoraCodes.connectionReason(99))
        assertEquals("STARTING", AgoraCodes.remoteAudioState(1))
        assertEquals("REMOTE_UNMUTED", AgoraCodes.remoteAudioReason(6))
        assertEquals(listOf("unknown", "none", "ethernet", "wifi", "2g", "3g", "4g", "5g"), (-1..6).map(AgoraCodes::netType))
    }

}
