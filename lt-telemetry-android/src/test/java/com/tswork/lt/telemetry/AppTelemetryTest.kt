package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.*
import com.tswork.lt.telemetry.lab.*
import org.junit.Assert.*
import org.junit.Test

/** Error log and device state, phase 1 (lt-error-device-telemetry 03: TC-1 … TC-13). */
class AppTelemetryTest {
    private val device = StaticDevice("android", "14", "1.2.3", model = "Google Pixel 8", brand = "Google")
    private val leg = TelemetryLeg(callId = "call-1", channel = "audio-lab", user = "001001", engine = "agora")

    private fun severities(json: String) = Regex("\"severityText\":\"([A-Z]+)\"").findAll(json).map { it.groupValues[1] }.toList()

    // TC-1 (AC-1): app_error carries its own severity; every existing record stays INFO and otherwise unchanged.
    @Test fun tc1_appErrorIsErrorAndEveryOtherRecordStaysInfo() {
        val event = Telemetry.sdkEvent(leg, "app_state", "app background", "background", 1L)
        val sample = Telemetry.qualitySecond(leg, AudioMetrics(rttMs = 10.0), 2L)
        val error = Telemetry.appError(AppError(ErrorDomain.RTC, "agora_error_17"), stage = "in_call", count = 1, atEpochMs = 3L, leg = leg)
        assertEquals("INFO", event.severity)
        assertEquals("ERROR", error.severity)
        val json = Telemetry.logsJson(listOf(event, sample, error), device, "lt-call-demo")
        assertEquals(listOf("INFO", "INFO", "ERROR"), severities(json))
        // The INFO record encodes exactly as before apart from the new device-wide device_brand.
        val alone = Telemetry.logsJson(listOf(event), device, "lt-call-demo")
        assertTrue(alone.contains(""""severityText":"INFO","body":{"stringValue":"sdk_event"}"""))
        assertTrue(alone.contains(""""key":"device_brand","value":{"stringValue":"Google"}"""))
        assertEquals("FATAL", AppError(ErrorDomain.APP_EXIT, "exit_low_memory", fatal = true).severity)
        assertEquals("WARN", AppError(ErrorDomain.SIGNALING, "ws_close_1006", severity = Severity.WARN).severity)
    }

    // TC-2 (AC-2), the counting part: first occurrence sends count=1, the end sends one total per code seen again.
    @Test fun tc2_sameCodeInOneCallIsSentOnceAndTotalledAtTheEnd() {
        val tally = AppErrorTally()
        val e = AppError(ErrorDomain.API, "http_503")
        assertEquals(1, tally.record(e))
        assertEquals(2, tally.record(e))
        assertEquals(3, tally.record(e))
        assertEquals(1, tally.record(AppError(ErrorDomain.API, "http_timeout")))
        assertEquals(listOf("http_503" to 3), tally.totals().map { it.first.code to it.second })
        tally.clear()
        assertTrue(tally.totals().isEmpty())
    }

    // TC-3 (AC-2): detail is scrubbed of IPs and email and capped at 240; without a call there is no call_id.
    @Test fun tc3_detailIsScrubbedAndCappedAndNoCallMeansNoCallId() {
        val raw = "connect 10.1.2.3:443 via [2001:db8::1] fe80::1%wlan0 for a@b.com, ver 1.2.3 at 12:30:45 " + "x".repeat(400)
        val record = Telemetry.appError(AppError(ErrorDomain.API, "http_timeout", detail = raw), "idle", 1, 5L, leg = null,
            context = TelemetryContext(netType = "wifi", carrier = "Chunghwa", country = "TW"))
        val detail = record.attributes.getValue("detail")
        assertTrue(detail.length <= 240)
        assertFalse(detail, detail.contains("10.1.2.3") || detail.contains("2001:db8") || detail.contains("fe80") || detail.contains("a@b.com"))
        assertTrue(detail, detail.contains("<ip>") && detail.contains("<email>"))
        assertTrue(detail, detail.contains("ver 1.2.3") && detail.contains("12:30:45"))
        // r2 m1: C++ names with "::" are not addresses (same as the Collector's rule); an IPv4-mapped address is masked whole.
        assertEquals("std::bad_alloc in Foo::Bar from <ip> and <ip>", Telemetry.scrub("std::bad_alloc in Foo::Bar from ::ffff:10.0.0.1 and ::1"))
        assertEquals("<ip> <ip>", Telemetry.scrub("2001:db8:0:0:0:0:0:1 fe80::1%wlan0"))
        // r2-m1: an address that ends a sentence is still masked (a dot followed by a digit would be IPv4-mapped).
        assertEquals("failed to connect to <ip>. Retry <ip>, then <ip>)", Telemetry.scrub("failed to connect to 2001:db8::1. Retry fe80::1, then ::1)"))
        val a = record.attributes
        assertFalse(a.containsKey("call_id"))
        assertFalse(a.containsKey("leg_uid"))
        assertEquals(mapOf("error_domain" to "api", "error_code" to "http_timeout", "stage" to "idle", "fatal" to "0", "count" to "1",
            "source" to "app", "net_type" to "wifi", "carrier" to "Chunghwa", "country" to "TW"), a - "detail")
        assertEquals("app_error", record.body)
        // In a call: identity of the leg (call_id, leg_uid as the platform's UInt32).
        val inCall = Telemetry.appError(AppError(ErrorDomain.RTC, "agora_error_17", fatal = true), "in_call", 1, 5L, leg = leg)
        assertEquals("call-1", inCall.attributes["call_id"]); assertEquals("1001", inCall.attributes["leg_uid"]); assertEquals("1", inCall.attributes["fatal"])
        // A pending leg (no call id yet) does not send an empty call_id.
        assertFalse(Telemetry.appError(AppError(ErrorDomain.RTC, "x"), "joining", 1, 5L, leg = leg.copy(callId = "")).attributes.containsKey("call_id"))
        // Every domain is one of the contract values (phase 2 added push).
        assertEquals(listOf("app_exit", "crash", "rtc", "api", "signaling", "audio", "permission", "telemetry", "push"), ErrorDomain.entries.map { it.code })
    }

    // TC-4 (AC-3), the mapping part: Agora callbacks become stable app_error codes and named sdk_event reasons.
    @Test fun tc4_agoraCallbacksMapToStableCodes() {
        assertEquals(AppError(ErrorDomain.RTC, "agora_error_17", "Agora SDK 回呼 失敗", fatal = true), AgoraCodes.onError(17, "Agora SDK 回呼 失敗"))
        assertEquals("agora_join_failed_17", AgoraCodes.joinFailed(-17, "x").code)
        assertEquals("agora_conn_failed_invalid_token", AgoraCodes.connectionFailed(8).code)
        assertTrue(AgoraCodes.connectionFailed(8).fatal)
        val audio = AgoraCodes.localAudioFailed(4)
        assertEquals(ErrorDomain.AUDIO to "agora_local_audio_failed_capture_failure", audio.domain to audio.code)
        assertEquals("agora_encryption_2", AgoraCodes.encryptionError(2).code)
        val permission = AgoraCodes.permissionError(0)
        assertEquals(ErrorDomain.PERMISSION to "agora_permission_record_audio", permission.domain to permission.code)
        assertEquals("interrupted", AgoraCodes.localAudioReason(8))
        assertEquals("device_no_permission", AgoraCodes.localAudioReason(2))
        assertEquals("reason_99", AgoraCodes.localAudioReason(99))
        assertEquals("dropped", AgoraCodes.userOfflineReason(1))
        assertEquals("quit", AgoraCodes.userOfflineReason(0))
        assertEquals("become_audience", AgoraCodes.userOfflineReason(2))
    }

    // TC-5 (AC-3), the mapping part: relay HTTP status, timeout and WebSocket close codes.
    @Test fun tc5_apiAndSignalingFailuresMapToStableCodes() {
        assertEquals("http_503", ApiErrors.code(RelayHttpException(503, "後端回應 503")))
        assertEquals("http_timeout", ApiErrors.code(java.net.SocketTimeoutException("timeout")))
        assertEquals("http_timeout", ApiErrors.code(java.io.InterruptedIOException("timeout")))
        assertEquals("http_network", ApiErrors.code(java.net.UnknownHostException("relay")))
        assertEquals("http_timeout", ApiErrors.status(-1)); assertEquals("http_network", ApiErrors.status(0)); assertEquals("http_429", ApiErrors.status(429))
        assertNull(ApiErrors.code(IllegalArgumentException("not an API failure")))
        assertEquals("ws_close_1006", SignalingErrors.closed(1006)?.code)
        assertEquals(ErrorDomain.SIGNALING, SignalingErrors.closed(1006)?.domain)
        assertEquals(Severity.WARN, SignalingErrors.closed(1006)?.severity) // It reconnects on its own.
        assertNull(SignalingErrors.closed(1000)) // A normal close is not an error.
        assertEquals("ws_connect_failed", SignalingErrors.connectFailed().code)
        assertEquals(Severity.ERROR, SignalingErrors.closed(4401)?.severity) // Ticket rejected: the call ends.
    }

    // TC-6 (AC-4): device state goes on quality_second; what the platform cannot tell is left out, never sent as 0.
    @Test fun tc6_qualitySecondCarriesKnownDeviceStateOnly() {
        val full = TelemetryContext(device = DeviceState(batteryPct = 19, powerSave = true, thermal = 0, micSilenced = false))
        val a = Telemetry.qualitySecond(leg, AudioMetrics(), 1L, full, appForeground = false).attributes
        assertEquals("0", a["app_fg"]); assertEquals("1", a["power_save"]); assertEquals("0", a["thermal"])
        assertEquals("0", a["mic_silenced"]); assertEquals("19", a["battery_pct"])
        val none = Telemetry.qualitySecond(leg, AudioMetrics(), 1L, TelemetryContext(), appForeground = null).attributes
        for (key in listOf("app_fg", "power_save", "thermal", "mic_silenced", "battery_pct")) assertFalse(key, none.containsKey(key))
        // Android 7 thermal levels onto the contract's 4 (0 nominal, 1 fair, 2 serious, 3 critical).
        assertEquals(listOf(0, 1, 1, 2, 3, 3, 3), (0..6).map { Thermal.android(it) })
        assertNull(Thermal.android(-1))
        assertEquals(listOf("nominal", "fair", "serious", "critical"), (0..3).map { Thermal.name(it) })
    }

    // TC-7 (AC-5): one env snapshot; device_power only on a change, battery thresholds once each.
    @Test fun tc7_envSnapshotAndDevicePowerChangesAreSentOnce() {
        val snapshot = Telemetry.envSnapshot(leg, DeviceState(batteryPct = 25, charging = false, powerSave = false, thermal = 1, doze = false,
            batteryOptExempt = true, bgRestricted = false, standbyBucket = "active", micPerm = "granted", notifPerm = "denied",
            fullscreenIntentPerm = "granted"), brand = "Google", atEpochMs = 1L).attributes
        assertEquals("env", snapshot["label"]); assertEquals("snapshot", snapshot["reason"])
        assertEquals(mapOf("battery_pct" to "25", "charging" to "0", "power_save" to "0", "thermal" to "1", "doze" to "0",
            "battery_opt_exempt" to "1", "bg_restricted" to "0", "standby_bucket" to "active", "mic_perm" to "granted",
            "notif_perm" to "denied", "fullscreen_intent_perm" to "granted", "device_brand" to "Google"),
            snapshot.filterKeys { it in setOf("battery_pct", "charging", "power_save", "thermal", "doze", "battery_opt_exempt", "bg_restricted",
                "standby_bucket", "mic_perm", "notif_perm", "fullscreen_intent_perm", "device_brand") })
        // iOS has no doze / standby bucket: an unknown field is not sent.
        assertFalse(Telemetry.envSnapshot(leg, DeviceState(batteryPct = 50), "Apple", 1L).attributes.containsKey("doze"))

        val watch = DeviceWatch()
        fun step(state: DeviceState) = watch.observe(TelemetryContext(device = state)).map { it.reason }
        assertEquals(emptyList<String>(), step(DeviceState(batteryPct = 25, powerSave = false, thermal = 0, doze = false)))
        assertEquals(emptyList<String>(), step(DeviceState(batteryPct = 25, powerSave = false, thermal = 0, doze = false)))
        assertEquals(listOf("power_save_on"), step(DeviceState(batteryPct = 25, powerSave = true, thermal = 0, doze = false)))
        assertEquals(listOf("thermal_serious"), step(DeviceState(batteryPct = 25, powerSave = true, thermal = 2, doze = false)))
        assertEquals(listOf("battery_low_20"), step(DeviceState(batteryPct = 19, powerSave = true, thermal = 2, doze = false)))
        assertEquals(emptyList<String>(), step(DeviceState(batteryPct = 21, powerSave = true, thermal = 2, doze = false)))
        assertEquals(emptyList<String>(), step(DeviceState(batteryPct = 19, powerSave = true, thermal = 2, doze = false))) // Not again.
        assertEquals(listOf("battery_low_10"), step(DeviceState(batteryPct = 9, powerSave = true, thermal = 2, doze = false)))
        assertEquals(listOf("battery_low_5", "doze_on"), step(DeviceState(batteryPct = 4, powerSave = true, thermal = 2, doze = true)))
        assertEquals(listOf("power_save_off", "thermal_nominal", "doze_off"), step(DeviceState(batteryPct = 4, powerSave = false, thermal = 0, doze = false)))
        // An unknown reading (platform gave nothing this second) is not a change.
        assertEquals(emptyList<String>(), step(DeviceState()))
        assertTrue(watch.observe(TelemetryContext(device = DeviceState(batteryPct = 4))).all { it.label == "device_power" })
        // A call that starts below a threshold is described by the snapshot, not by a battery_low event.
        // r2 n1: battery unknown in the first second, then already at 4%: the snapshot's job, not three battery_low events.
        val late = DeviceWatch()
        assertEquals(emptyList<String>(), late.observe(TelemetryContext(device = DeviceState())).map { it.reason })
        assertEquals(emptyList<String>(), late.observe(TelemetryContext(device = DeviceState(batteryPct = 4))).map { it.reason })
        val low = DeviceWatch()
        assertEquals(emptyList<String>(), low.observe(TelemetryContext(device = DeviceState(batteryPct = 15))).map { it.reason })
        assertEquals(listOf("battery_low_10"), low.observe(TelemetryContext(device = DeviceState(batteryPct = 9))).map { it.reason })
    }

    // TC-8 (AC-6): system mic silencing, a cellular call and audio focus each become one mic event per change.
    @Test fun tc8_micSilencedAndFocusChangesBecomeMicEvents() {
        val watch = DeviceWatch()
        fun step(silenced: Boolean?, phone: Boolean? = false) =
            watch.observe(TelemetryContext(device = DeviceState(micSilenced = silenced, phoneCall = phone))).map { it.label to it.reason }
        assertEquals(emptyList<Pair<String, String>>(), step(false))
        assertEquals(listOf("mic" to "silenced"), step(true))
        assertEquals(emptyList<Pair<String, String>>(), step(true))
        assertEquals(listOf("mic" to "unsilenced"), step(false))
        assertEquals(listOf("mic" to "interrupted_by_call"), step(false, phone = true))
        assertEquals(emptyList<Pair<String, String>>(), step(false, phone = false)) // The end shows as unsilenced/focus_gained, not a reason of its own.
        assertEquals(listOf("focus_lost", "focus_gained", "permission_denied", "media_reset"),
            listOf(MicEvent.FOCUS_LOST, MicEvent.FOCUS_GAINED, MicEvent.PERMISSION_DENIED, MicEvent.MEDIA_RESET).map { it.reason })
        assertEquals(listOf("permission_denied", "silenced", "unsilenced", "focus_lost", "focus_gained", "interrupted_by_call", "media_reset", "silent_capture"),
            MicEvent.entries.map { it.reason })
    }

    // TC-9 (AC-6): ten seconds of zero mic volume while unmuted and sending is silent_capture; a muted user is not.
    @Test fun tc9_silentCaptureNeedsTenSilentUnmutedSendingSeconds() {
        val watch = DeviceWatch()
        val silent = AudioMetrics(sendKbps = 24.0, extra = mapOf("agora_mic_volume" to "0"))
        val hits = (1..12).map { watch.silentCapture(silent, muted = false) }
        assertEquals(listOf(false, false, false, false, false, false, false, false, false, true, false, false), hits)
        // Speaking again re-arms it.
        assertFalse(watch.silentCapture(silent.copy(extra = mapOf("agora_mic_volume" to "30")), muted = false))
        assertEquals(10, (1..10).count { !watch.silentCapture(silent, muted = false) } + 1)
        val muted = DeviceWatch()
        assertTrue((1..20).none { muted.silentCapture(silent, muted = true) })
        val notSending = DeviceWatch()
        assertTrue((1..20).none { notSending.silentCapture(silent.copy(sendKbps = 0.0), muted = false) })
        val unknown = DeviceWatch() // No mic volume (non-Agora engines): never guessed.
        assertTrue((1..20).none { unknown.silentCapture(AudioMetrics(sendKbps = 24.0), muted = false) })
    }

    // TC-12 (AC-8): a durable queue survives a failed send and a restart, sends once, and drops the oldest over its cap.
    @Test fun tc12_durableQueueSendsOnceAfterRestartAndDropsOldestOverCap() {
        val store = object : TextStore { var text: String? = null; override fun read() = text; override fun write(text: String) { this.text = text } }
        val record = Telemetry.appError(AppError(ErrorDomain.API, "http_503", detail = "a=b&c\td\nline 中文"), "idle", 1, 7L, leg = null)
        val first = DurableTelemetryQueue(store, cap = 3)
        first.add(listOf(record))
        assertFalse(first.drain { DurableTelemetryQueue.Outcome.RETRY }) // Offline.
        val restarted = DurableTelemetryQueue(store, cap = 3)
        val sent = mutableListOf<TelemetryRecord>()
        assertTrue(restarted.drain { sent += it; DurableTelemetryQueue.Outcome.SENT })
        assertEquals(listOf(record), sent)
        assertTrue(DurableTelemetryQueue(store, cap = 3).drain { sent += it; DurableTelemetryQueue.Outcome.SENT })
        assertEquals(1, sent.size) // Not again.
        val capped = DurableTelemetryQueue(store, cap = 3)
        capped.add((1..5).map { record.copy(atEpochMs = it.toLong()) })
        assertEquals(listOf(3L, 4L, 5L), capped.pending().map { it.atEpochMs })
        // A permanent rejection is dropped too, so it cannot block later records.
        assertTrue(capped.drain { DurableTelemetryQueue.Outcome.REJECTED })
        assertTrue(capped.pending().isEmpty())
        // A corrupt file is ignored rather than crashing the app at launch.
        store.text = "garbage\nmore"
        assertTrue(DurableTelemetryQueue(store, cap = 3).pending().isEmpty())
        assertTrue(DurableTelemetryQueue.isDurable(record))
        assertFalse(DurableTelemetryQueue.isDurable(Telemetry.sdkEvent(leg, "app_state", "x", "background", 1L)))
    }

    // TC-10 (AC-7), the marker part: what is written to disk while a call runs is enough to report it later.
    @Test fun tc10_callMarkerRoundTripsAndExitReasonsHaveNames() {
        val marker = CallMarker(callId = "c-1", channel = "room 1&2", user = "1001", engine = "agora", sdkVersion = "agora-4.7.0", startedAtMs = 42L)
        assertEquals(marker, CallMarker.decode(marker.encode()))
        assertNull(CallMarker.decode("nonsense"))
        assertNull(CallMarker.decode(""))
        assertEquals("low_memory", ExitReasons.android(3))
        assertEquals("freezer", ExitReasons.android(14))
        assertEquals("user_requested", ExitReasons.android(10))
        assertEquals("signaled", ExitReasons.android(2))
        assertEquals("unknown", ExitReasons.android(0))
        assertEquals("reason_99", ExitReasons.android(99))
        val exit = Telemetry.abnormalExit(marker, "low_memory", 9L)
        assertEquals(mapOf("label" to "abnormal_exit", "reason" to "abnormal_exit", "event" to "abnormal exit", "detail" to "exit_reason=low_memory",
            "call_id" to "c-1", "channel" to "room 1&2", "leg_uid" to "1001", "engine" to "agora", "sdk_version" to "agora-4.7.0"), exit.attributes)
    }

    // TC-13 (AC-9): one app_start per process, no call identity; device fields come from logsJson.
    @Test fun tc13_appStartIsAPlainEventWithDeviceFields() {
        val start = Telemetry.appStart(5L)
        assertEquals(mapOf("label" to "app_start", "reason" to "app_start", "event" to "app start"), start.attributes)
        val json = Telemetry.logsJson(listOf(start), device, "lt-call-demo")
        for (key in listOf("platform", "app_version", "os_version", "device_brand", "device_model")) assertTrue(key, json.contains("\"key\":\"$key\""))
    }
}
