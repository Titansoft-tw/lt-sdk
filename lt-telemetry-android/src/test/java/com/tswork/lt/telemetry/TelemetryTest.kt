package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.*
import com.tswork.lt.telemetry.lab.*
import org.junit.Assert.*
import org.junit.Test

class TelemetryTest {
    private val leg = TelemetryLeg(callId = "c1", channel = "room-1", user = "001234", peer = "567890", engine = "webrtc", role = "caller")

    @Test fun qualitySecondMapsMeasuredFieldsAndOmitsTheRest() {
        val record = Telemetry.qualitySecond(leg, AudioMetrics(lossPct = 1.234, jitterMs = 4.6, rttMs = 180.4,
            receiveKbps = 26.0, jitterBufferMs = 119.5, protocol = "UDP", candidateType = "relay", relayProtocol = "TCP",
            codec = "audio/opus"), 1_700_000_000_123)
        val a = record.attributes
        assertEquals("quality_second", record.body)
        assertEquals("c1", a["call_id"])
        assertEquals("room-1", a["channel"])
        assertEquals("1234", a["leg_uid"])
        assertEquals("567890", a["peer_uid"])
        assertEquals("webrtc", a["engine"])
        assertEquals("caller", a["role"])
        assertEquals("26.00", a["rx_audio_kbps"])
        assertEquals("1.23", a["rx_loss_pct"])
        // Integer columns on the platform: a decimal string would be stored as 0.
        assertEquals("180", a["rtt_ms"])
        assertEquals("5", a["jitter_ms"])
        assertEquals("120", a["jitter_buffer_ms"])
        assertEquals("udp", a["transport"])
        assertEquals("1", a["relay"])
        assertEquals("tcp", a["relay_protocol"])
        // Not measured on this engine: absent, never zero.
        assertFalse("tx_audio_kbps" in a)
        assertFalse("e2e_delay_ms" in a)
        assertFalse("mos" in a)
    }

    @Test fun directPathIsNotRelayAndUnknownPathIsOmitted() {
        assertEquals("0", Telemetry.qualitySecond(leg, AudioMetrics(candidateType = "srflx"), 0).attributes["relay"])
        assertFalse("relay" in Telemetry.qualitySecond(leg, AudioMetrics(), 0).attributes)
        assertFalse("peer_uid" in Telemetry.qualitySecond(leg.copy(peer = ""), AudioMetrics(), 0).attributes)
    }

    @Test fun logsJsonIsOtlpWithStringValuesAndDeviceFields() {
        val event = Telemetry.sdkEvent(leg, "audio_sending", "the user muted \"local\" audio\n", "muted", 1_700_000_000_123)
        val json = Telemetry.logsJson(listOf(event), StaticDevice("android", "15", "0.1.0", "", ""), "lt-call-demo")
        assertTrue(json.startsWith("""{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"lt-call-demo"}}]}"""))
        assertTrue(""""timeUnixNano":"1700000000123000000"""" in json)
        assertTrue(""""body":{"stringValue":"sdk_event"}""" in json)
        assertTrue("""{"key":"reason","value":{"stringValue":"muted"}}""" in json)
        assertTrue("""{"key":"platform","value":{"stringValue":"android"}}""" in json)
        assertTrue("""{"key":"os_version","value":{"stringValue":"15"}}""" in json)
        assertTrue("""the user muted \"local\" audio\u000a""" in json)
    }

    @Test fun contextAndUplinkFieldsAreSentWhenKnown() {
        val context = TelemetryContext(netType = "5g", carrier = "CHT", country = "TW",
            audioRoute = "bluetooth", audioDevice = "AirPods Pro", btProfile = "hfp")
        val a = Telemetry.qualitySecond(leg, AudioMetrics(sendKbps = 31.5, sendLossPct = 2.0, freezePct = 4.5), 0, context).attributes
        assertEquals("5g", a["net_type"])
        assertEquals("CHT", a["carrier"])
        assertEquals("TW", a["country"])
        assertEquals("bluetooth", a["audio_route"])
        assertEquals("AirPods Pro", a["audio_device"])
        assertEquals("hfp", a["bt_profile"])
        assertEquals("31.50", a["tx_audio_kbps"])
        assertEquals("2.00", a["tx_loss_pct"])
        assertEquals("4.50", a["freeze_rate_pct"])
        val blank = Telemetry.qualitySecond(leg, AudioMetrics(), 0).attributes
        assertFalse("net_type" in blank)
        assertFalse("audio_device" in blank)
    }

    @Test fun switchEventsFollowThePlatformContract() {
        val net = Telemetry.netChanged(leg, "wifi", "5g", 0).attributes
        assertEquals("network", net["label"])
        assertEquals("net_changed", net["reason"])
        assertEquals("network changed wifi -> 5g", net["event"])
        val route = Telemetry.routeChanged(leg, TelemetryContext(audioRoute = "speaker"),
            TelemetryContext(audioRoute = "bluetooth", audioDevice = "AirPods Pro", btProfile = "hfp"), 0).attributes
        assertEquals("audio_route", route["label"])
        assertEquals("route_changed", route["reason"])
        assertEquals("audio route changed speaker -> bluetooth (AirPods Pro, hfp)", route["event"])
        assertEquals("reconnected on 5g", Telemetry.reconnecting(leg, false, "5g", 0).attributes["event"])
        assertEquals("reconnecting", Telemetry.reconnecting(leg, true, "5g", 0).attributes["reason"])
    }

    @Test fun serverRegionIsSentOnlyWhenKnown() {
        val withRegion = Telemetry.qualitySecond(leg.copy(engine = "livekit_onprem", region = "hk"), AudioMetrics(), 1_000L)
        assertEquals("hk", withRegion.attributes["server_region"])
        assertFalse(Telemetry.qualitySecond(leg, AudioMetrics(), 1_000L).attributes.containsKey("server_region"))
    }
    @Test fun engineExtrasArePassedThrough() {
        val record = Telemetry.qualitySecond(leg, AudioMetrics(extra = mapOf("agora_mos_raw" to "432", "rtc_nack_count" to "2.0")), 1_000L)
        assertEquals("432", record.attributes["agora_mos_raw"])
        assertEquals("2.0", record.attributes["rtc_nack_count"])
    }
    @Test fun labRunIdentityRidesOnEveryRecordAndTheRatingStandsAlone() {
        val tag = LabTag(runId = "r1abc123456", caseId = "SMK-01", role = "B")
        val sample = Telemetry.qualitySecond(leg.copy(lab = tag), AudioMetrics(), 1_000L).attributes
        assertEquals(listOf("r1abc123456", "SMK-01", "B"), listOf(sample["test_run_id"], sample["case_id"], sample["test_role"]))
        assertFalse(Telemetry.qualitySecond(leg, AudioMetrics(), 1_000L).attributes.containsKey("test_run_id"))
        val rating = LabTelemetry.caseResult(tag, "livekit_onprem", "hk", clarity = 4, noDrop = 9, atEpochMs = 2_000L)
        assertEquals(LabTelemetry.CASE_RESULT, rating.body)
        assertEquals("4", rating.attributes["rating_clarity"])
        assertEquals("5", rating.attributes["rating_drop"]) // Clamped to 1..5.
        assertEquals("hk", rating.attributes["server_region"])
    }

    @Test fun exitCountryAndSignalGoOnEverySecondAndOnTheLobbyProbe() {
        val ctx = TelemetryContext(netType = "wifi", vpn = "1", exitCountry = "JP",
            signal = mapOf("wifi_rssi_dbm" to "-61", "wifi_band_ghz" to "5", "cell_level" to "3"))
        val leg = TelemetryLeg(callId = "c", channel = "t1", user = "1", engine = "agora")
        val second = Telemetry.qualitySecond(leg, AudioMetrics(), 1, ctx).attributes
        assertEquals("JP", second["exit_country"]); assertEquals("-61", second["wifi_rssi_dbm"]); assertEquals("3", second["cell_level"])
        val probe = LabTelemetry.netProbe(LabTag("r1", "SMK-01", "A", 2), mapOf("tw" to 18L, "us" to null), ctx, 1)
        assertEquals("net_probe", probe.body)
        assertEquals("18", probe.attributes["probe_tw_ms"]); assertEquals("", probe.attributes["probe_us_ms"])
        assertEquals("r1", probe.attributes["test_run_id"]); assertEquals("2", probe.attributes["test_group"])
        assertEquals("JP", probe.attributes["exit_country"]); assertEquals("5", probe.attributes["wifi_band_ghz"])
    }

    @Test fun sessionTimeSignalEventsAndProbePhaseAreSeparateAttributes() {
        val leg = TelemetryLeg(callId = "c", channel = "t1", user = "1", engine = "webrtc")
        val setup = Telemetry.callSetup(leg, SetupStage.TOKEN_OK, "", 5, mapOf("session_ms" to "212")).attributes
        assertEquals("token_ok", setup["reason"]); assertEquals("212", setup["session_ms"])
        val signal = Telemetry.sdkEvent(leg, "signal_channel", "connect", "ok", 6, extra = mapOf("signal_connect_ms" to "87")).attributes
        assertEquals("signal_channel", signal["label"]); assertEquals("87", signal["signal_connect_ms"])
        val ctx = TelemetryContext()
        val tag = LabTag("r1", "SMK-01", "A", 2)
        assertEquals("lobby", LabTelemetry.netProbe(tag, mapOf("relay" to 30L), ctx, 1).attributes["probe_phase"])
        val mid = LabTelemetry.netProbe(tag, mapOf("relay" to 31L), ctx, 2, "in_call").attributes
        assertEquals("in_call", mid["probe_phase"]); assertEquals("31", mid["probe_relay_ms"])
    }
}
