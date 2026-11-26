package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.*
import com.tswork.lt.telemetry.lab.*
import org.junit.Assert.*
import org.junit.Test

/** Keys, credentials and the E2EE safety code must never reach lt-observability (docs/e2ee.md). */
class TelemetrySecretGuardTest {
    private val device = StaticDevice("android", "15", "0.1.0", "", "")
    private val leg = TelemetryLeg(callId = "call-1", channel = "123456", user = "100001", engine = "webrtc", sdkVersion = "webrtc-1")

    @Test fun encoderDropsAttributesThatLookLikeSecrets() {
        val record = TelemetryRecord(Telemetry.SDK_EVENT, 1_700_000_000_000L, mapOf(
            "call_id" to "call-1",
            "media_key" to "fake-media-key-material",
            "e2ee_pub" to "ok-to-drop-too",
            "apiKey" to "fake-api-key",
            "token" to "fake-token",
            "turn_credential" to "fake-credential",
            "client_secret" to "fake-secret",
            "private_key" to "fake-private",
            "safety_code" to "123456",
            "ticket" to "fake-ticket",
            "sdp" to "v=0",
            "Authorization" to "Bearer fake",
            "label" to "call_setup",
        ))
        val json = Telemetry.logsJson(listOf(record), device, "lt-call-demo")
        for (value in listOf("fake-media-key-material", "fake-api-key", "fake-token", "fake-credential", "fake-secret",
            "fake-private", "\"123456\"", "fake-ticket", "v=0", "Bearer fake")) {
            assertFalse("leaked $value", json.contains(value))
        }
        assertTrue(json.contains("\"call_id\""))
        assertTrue(json.contains("\"label\""))
    }

    @Test fun everyAttributeTheAppSendsTodayPassesTheGuard() {
        val metrics = AudioMetrics(rttMs = 40.0, lossPct = 1.0, jitterMs = 5.0, protocol = "UDP", candidateType = "relay",
            relayProtocol = "udp", codec = "opus", concealPct = 0.5, mos = 4.2, sendKbps = 32.0, receiveKbps = 30.0)
        val context = TelemetryContext("wifi", "Carrier", "TW", "bluetooth", "AirPods", "hfp")
        val records = listOf(Telemetry.qualitySecond(leg, metrics, 1L, context), Telemetry.sdkEvent(leg, "audio_sending", "muted", "muted", 1L))
        val names = records.flatMap { it.attributes.keys } + listOf("platform", "os_version", "app_version", "sdk_version")
        assertTrue(names.filter(Telemetry::isSecretAttribute).toString(), names.none(Telemetry::isSecretAttribute))
        val json = Telemetry.logsJson(records, device, "lt-call-demo")
        names.forEach { assertTrue(it, json.contains("\"$it\"")) }
    }
}
