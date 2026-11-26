import Foundation
import Testing
@testable import LtTelemetry

// Port of lt-call-demo AppTelemetryTest.kt: error log and device state, phase 1 (lt-error-device-telemetry 03: TC-1 … TC-13).

private let device = StaticDevice(platform: "ios", osVersion: "18.1", appVersion: "1.2.3", model: "Apple iPhone14,2", brand: "Apple")
private let leg = TelemetryLeg(callId: "call-1", channel: "audio-lab", user: "001001", engine: "agora")

private func logRecords(_ records: [TelemetryRecord]) -> [[String: Any]] {
    let json = Telemetry.logsJson(records, device: device, serviceName: "lt-call-demo")
    let scope = ((json["resourceLogs"] as! [[String: Any]])[0]["scopeLogs"] as! [[String: Any]])[0]
    return scope["logRecords"] as! [[String: Any]]
}
private func attributes(_ record: [String: Any]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (record["attributes"] as! [[String: Any]]).map {
        ($0["key"] as! String, ($0["value"] as! [String: Any])["stringValue"] as! String)
    })
}

final class MemoryStore: TextStore {
    var text: String?
    func read() -> String? { text }
    func write(_ text: String) { self.text = text }
}

@MainActor struct AppTelemetryTests {
    // TC-1 (AC-1): app_error carries its own severity; every existing record stays INFO and otherwise unchanged.
    @Test func tc1_appErrorIsErrorAndEveryOtherRecordStaysInfo() {
        let event = Telemetry.sdkEvent(leg, label: "app_state", event: "app background", reason: "background", atEpochMs: 1)
        let sample = Telemetry.qualitySecond(leg, AudioMetrics(rttMs: 10), atEpochMs: 2)
        let error = Telemetry.appError(AppError(.rtc, "agora_error_17"), stage: "in_call", count: 1, atEpochMs: 3, leg: leg)
        #expect(event.severity == "INFO")
        #expect(error.severity == "ERROR")
        let logs = logRecords([event, sample, error])
        #expect(logs.map { $0["severityText"] as? String } == ["INFO", "INFO", "ERROR"])
        #expect(attributes(logs[0])["device_brand"] == "Apple")
        #expect(attributes(logs[0])["label"] == "app_state")
        #expect(AppError(.appExit, "exit_unknown", fatal: true).severity == "FATAL")
        #expect(AppError(.signaling, "ws_close_1006", severity: Severity.warn).severity == "WARN")
        // Stamping keeps the severity.
        #expect(Telemetry.stamp(error, callId: "c", testScenario: "").severity == "ERROR")
    }

    // TC-2 (AC-2), the counting part.
    @Test func tc2_sameCodeInOneCallIsSentOnceAndTotalledAtTheEnd() {
        var tally = AppErrorTally()
        let e = AppError(.api, "http_503")
        #expect(tally.record(e) == 1)
        #expect(tally.record(e) == 2)
        #expect(tally.record(e) == 3)
        #expect(tally.record(AppError(.api, "http_timeout")) == 1)
        #expect(tally.totals().map { "\($0.error.code)=\($0.count)" } == ["http_503=3"])
        tally.clear()
        #expect(tally.totals().isEmpty)
    }

    // TC-3 (AC-2): detail is scrubbed of IPs and email and capped at 240; without a call there is no call_id.
    @Test func tc3_detailIsScrubbedAndCappedAndNoCallMeansNoCallId() {
        let raw = "connect 10.1.2.3:443 via [2001:db8::1] fe80::1%en0 for a@b.com, ver 1.2.3 at 12:30:45 " + String(repeating: "x", count: 400)
        let record = Telemetry.appError(AppError(.api, "http_timeout", detail: raw), stage: "idle", count: 1, atEpochMs: 5,
                                        context: TelemetryContext(netType: "wifi", carrier: "Chunghwa", country: "TW"))
        let detail = record.attributes["detail"]!
        #expect(detail.count <= 240)
        #expect(!detail.contains("10.1.2.3") && !detail.contains("2001:db8") && !detail.contains("fe80") && !detail.contains("a@b.com"))
        #expect(detail.contains("<ip>") && detail.contains("<email>"))
        #expect(detail.contains("ver 1.2.3") && detail.contains("12:30:45"))
        // r2 m1: C++ names with "::" are not addresses (same as the Collector's rule); an IPv4-mapped address is masked whole.
        #expect(Telemetry.scrub("std::bad_alloc in Foo::Bar from ::ffff:10.0.0.1 and ::1") == "std::bad_alloc in Foo::Bar from <ip> and <ip>")
        #expect(Telemetry.scrub("2001:db8:0:0:0:0:0:1 fe80::1%en0") == "<ip> <ip>")
        // r2-m1: an address that ends a sentence is still masked (a dot followed by a digit would be IPv4-mapped).
        #expect(Telemetry.scrub("failed to connect to 2001:db8::1. Retry fe80::1, then ::1)") == "failed to connect to <ip>. Retry <ip>, then <ip>)")
        var a = record.attributes
        a["detail"] = nil
        #expect(a == ["error_domain": "api", "error_code": "http_timeout", "stage": "idle", "fatal": "0", "count": "1",
                      "source": "app", "net_type": "wifi", "carrier": "Chunghwa", "country": "TW"])
        #expect(record.body == "app_error")
        let inCall = Telemetry.appError(AppError(.rtc, "agora_error_17", fatal: true), stage: "in_call", count: 1, atEpochMs: 5, leg: leg)
        #expect(inCall.attributes["call_id"] == "call-1" && inCall.attributes["leg_uid"] == "1001" && inCall.attributes["fatal"] == "1")
        var pending = leg
        pending.callId = ""
        #expect(Telemetry.appError(AppError(.rtc, "x"), stage: "joining", count: 1, atEpochMs: 5, leg: pending).attributes["call_id"] == nil)
        #expect(ErrorDomain.allCases.map(\.rawValue) == ["app_exit", "crash", "rtc", "api", "signaling", "audio", "permission", "telemetry", "push"]) // phase 2 added push
    }

    // TC-4 (AC-3), the mapping part: Agora callbacks become stable app_error codes and named sdk_event reasons.
    @Test func tc4_agoraCallbacksMapToStableCodes() {
        #expect(AgoraCodes.onError(17, detail: "d") == AppError(.rtc, "agora_error_17", detail: "d", fatal: true))
        #expect(AgoraCodes.joinFailed(-17, detail: "x").code == "agora_join_failed_17")
        #expect(AgoraCodes.connectionFailed(8).code == "agora_conn_failed_invalid_token")
        #expect(AgoraCodes.connectionFailed(8).fatal)
        #expect(AgoraCodes.localAudioFailed(4).domain == .audio)
        #expect(AgoraCodes.localAudioFailed(4).code == "agora_local_audio_failed_capture_failure")
        #expect(AgoraCodes.encryptionError(2).code == "agora_encryption_2")
        #expect(AgoraCodes.permissionError(0).domain == .permission)
        #expect(AgoraCodes.permissionError(0).code == "agora_permission_record_audio")
        #expect(AgoraCodes.localAudioReason(8) == "interrupted")
        #expect(AgoraCodes.localAudioReason(2) == "device_no_permission")
        #expect(AgoraCodes.localAudioReason(99) == "reason_99")
        #expect(AgoraCodes.localAudioState(3) == "failed")
        #expect([0, 1, 2].map(AgoraCodes.userOfflineReason) == ["quit", "dropped", "become_audience"])
    }

    // TC-5 (AC-3), the mapping part: relay HTTP status, timeout and WebSocket close codes.
    @Test func tc5_apiAndSignalingFailuresMapToStableCodes() {
        #expect(ApiErrors.code(RelayHttpError(status: 503, message: "後端回應 503")) == "http_503")
        #expect(ApiErrors.code(URLError(.timedOut)) == "http_timeout")
        #expect(ApiErrors.code(URLError(.cannotFindHost)) == "http_network")
        #expect(ApiErrors.status(-1) == "http_timeout" && ApiErrors.status(0) == "http_network" && ApiErrors.status(429) == "http_429")
        #expect(ApiErrors.code(CocoaError(.featureUnsupported)) == nil)
        #expect(SignalingErrors.closed(1006)?.code == "ws_close_1006")
        #expect(SignalingErrors.closed(1006)?.domain == .signaling)
        #expect(SignalingErrors.closed(1006)?.severity == "WARN")
        #expect(SignalingErrors.closed(1000) == nil)
        #expect(SignalingErrors.connectFailed().code == "ws_connect_failed")
        #expect(SignalingErrors.closed(4401)?.severity == "ERROR")
    }

    // TC-6 (AC-4): device state goes on quality_second; what the platform cannot tell is left out, never sent as 0.
    @Test func tc6_qualitySecondCarriesKnownDeviceStateOnly() {
        let full = TelemetryContext(device: DeviceState(batteryPct: 19, powerSave: true, thermal: 0, micSilenced: false))
        let a = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 1, context: full, appForeground: false).attributes
        #expect(a["app_fg"] == "0" && a["power_save"] == "1" && a["thermal"] == "0" && a["mic_silenced"] == "0" && a["battery_pct"] == "19")
        let none = Telemetry.qualitySecond(leg, AudioMetrics(), atEpochMs: 1, context: TelemetryContext(), appForeground: nil).attributes
        for key in ["app_fg", "power_save", "thermal", "mic_silenced", "battery_pct"] { #expect(none[key] == nil, "\(key)") }
        #expect((0...3).map { Thermal.ios($0) } == [0, 1, 2, 3])
        #expect(Thermal.ios(7) == nil)
        #expect((0...6).map { Thermal.android($0) } == [0, 1, 1, 2, 3, 3, 3])
        #expect((0...3).map(Thermal.name) == ["nominal", "fair", "serious", "critical"])
    }

    // TC-7 (AC-5): one env snapshot; device_power only on a change, battery thresholds once each.
    @Test func tc7_envSnapshotAndDevicePowerChangesAreSentOnce() {
        let snapshot = Telemetry.envSnapshot(leg, DeviceState(batteryPct: 25, charging: false, powerSave: false, thermal: 1, micPerm: "granted",
                                                               notifPerm: "undetermined"), brand: "Apple", atEpochMs: 1).attributes
        #expect(snapshot["label"] == "env" && snapshot["reason"] == "snapshot")
        #expect(snapshot["battery_pct"] == "25" && snapshot["charging"] == "0" && snapshot["power_save"] == "0" && snapshot["thermal"] == "1")
        #expect(snapshot["mic_perm"] == "granted" && snapshot["notif_perm"] == "undetermined" && snapshot["device_brand"] == "Apple")
        // iOS has no doze, standby bucket or battery optimisation: not sent.
        #expect(snapshot["doze"] == nil && snapshot["standby_bucket"] == nil && snapshot["battery_opt_exempt"] == nil)

        var watch = DeviceWatch()
        func step(_ state: DeviceState) -> [String] { let changes = watch.observe(TelemetryContext(device: state)); return changes.map(\.reason) }
        #expect(step(DeviceState(batteryPct: 25, powerSave: false, thermal: 0)) == [])
        #expect(step(DeviceState(batteryPct: 25, powerSave: false, thermal: 0)) == [])
        #expect(step(DeviceState(batteryPct: 25, powerSave: true, thermal: 0)) == ["power_save_on"])
        #expect(step(DeviceState(batteryPct: 25, powerSave: true, thermal: 2)) == ["thermal_serious"])
        #expect(step(DeviceState(batteryPct: 19, powerSave: true, thermal: 2)) == ["battery_low_20"])
        #expect(step(DeviceState(batteryPct: 21, powerSave: true, thermal: 2)) == [])
        #expect(step(DeviceState(batteryPct: 19, powerSave: true, thermal: 2)) == [])
        #expect(step(DeviceState(batteryPct: 9, powerSave: true, thermal: 2)) == ["battery_low_10"])
        #expect(step(DeviceState(batteryPct: 4, powerSave: true, thermal: 3)) == ["thermal_critical", "battery_low_5"])
        #expect(step(DeviceState(batteryPct: 4, powerSave: false, thermal: 0)) == ["power_save_off", "thermal_nominal"])
        #expect(step(DeviceState()) == [])
        // r2 n1: battery unknown in the first second, then already at 4%: the snapshot's job, not three battery_low events.
        var late = DeviceWatch()
        let unknownFirst = late.observe(TelemetryContext(device: DeviceState()))
        let lateLow = late.observe(TelemetryContext(device: DeviceState(batteryPct: 4)))
        #expect(unknownFirst.isEmpty && lateLow.isEmpty)
        var low = DeviceWatch()
        let start = low.observe(TelemetryContext(device: DeviceState(batteryPct: 15)))
        let next = low.observe(TelemetryContext(device: DeviceState(batteryPct: 9)))
        #expect(start.isEmpty)
        #expect(next.map(\.reason) == ["battery_low_10"])
    }

    // TC-8 (AC-6): system mic silencing (iOS: an interruption in progress) becomes one mic event per change.
    @Test func tc8_micSilencedChangesBecomeMicEvents() {
        var watch = DeviceWatch()
        func step(_ silenced: Bool?) -> [String] {
            let changes = watch.observe(TelemetryContext(device: DeviceState(micSilenced: silenced)))
            return changes.map { "\($0.label):\($0.reason)" }
        }
        #expect(step(false) == [])
        #expect(step(true) == ["mic:silenced"])
        #expect(step(true) == [])
        #expect(step(nil) == [])
        #expect(step(false) == ["mic:unsilenced"])
        #expect(MicEvent.allCases.map(\.reason) == ["permission_denied", "silenced", "unsilenced", "focus_lost", "focus_gained",
                                                     "interrupted_by_call", "media_reset", "silent_capture"])
    }

    // TC-8 (AC-6), r2 m3: only another real call is interrupted_by_call; Siri/alarms and appWasSuspended are not.
    @Test func tc8_onlyAnotherCallIsInterruptedByCall() {
        #expect(MicInterruption.event(began: true, reason: "default", otherCallActive: true) == .interruptedByCall)
        #expect(MicInterruption.event(began: true, reason: "default", otherCallActive: false) == nil) // Siri, an alarm
        #expect(MicInterruption.event(began: true, reason: "appWasSuspended", otherCallActive: true) == nil)
        #expect(MicInterruption.event(began: true, reason: "builtInMicMuted", otherCallActive: true) == nil)
        #expect(MicInterruption.event(began: false, reason: "default", otherCallActive: true) == nil)
    }

    // TC-9 (AC-6): ten seconds of zero mic volume while unmuted and sending is silent_capture; a muted user is not.
    @Test func tc9_silentCaptureNeedsTenSilentUnmutedSendingSeconds() {
        var watch = DeviceWatch()
        var silent = AudioMetrics(sendKbps: 24)
        silent.extra = ["agora_mic_volume": "0"]
        var hits: [Bool] = []
        for _ in 1...12 { hits.append(watch.silentCapture(silent, muted: false)) }
        #expect(hits == [false, false, false, false, false, false, false, false, false, true, false, false])
        var speaking = silent
        speaking.extra["agora_mic_volume"] = "30"
        let spoke = watch.silentCapture(speaking, muted: false)
        #expect(!spoke)
        var again: [Bool] = []
        for _ in 1...10 { again.append(watch.silentCapture(silent, muted: false)) }
        #expect(again.last == true && again.dropLast().allSatisfy { !$0 }) // Re-armed by speech.
        var idle = silent
        idle.sendKbps = 0
        var muted = DeviceWatch(), notSending = DeviceWatch(), unknown = DeviceWatch()
        var any = false
        for _ in 1...20 {
            any = any || muted.silentCapture(silent, muted: true)
            any = any || notSending.silentCapture(idle, muted: false)
            any = any || unknown.silentCapture(AudioMetrics(sendKbps: 24), muted: false)
        }
        #expect(!any)
    }

    // TC-12 (AC-8): a durable queue survives a failed send and a restart, sends once, and drops the oldest over its cap.
    @Test func tc12_durableQueueSendsOnceAfterRestartAndDropsOldestOverCap() async {
        let store = MemoryStore()
        let record = Telemetry.appError(AppError(.api, "http_503", detail: "a=b&c\td\nline 中文"), stage: "idle", count: 1, atEpochMs: 7)
        let first = DurableTelemetryQueue(store: store, cap: 3)
        first.add([record])
        #expect(await first.drain { _ in .retry } == false)
        let restarted = DurableTelemetryQueue(store: store, cap: 3)
        var sent: [TelemetryRecord] = []
        #expect(await restarted.drain { sent += $0; return .sent })
        #expect(sent == [record])
        #expect(await DurableTelemetryQueue(store: store, cap: 3).drain { sent += $0; return .sent })
        #expect(sent.count == 1)
        let capped = DurableTelemetryQueue(store: store, cap: 3)
        capped.add((1...5).map { TelemetryRecord(body: record.body, atEpochMs: Int64($0), attributes: record.attributes, severity: record.severity) })
        #expect(capped.pending.map(\.atEpochMs) == [3, 4, 5])
        #expect(await capped.drain { _ in .rejected })
        #expect(capped.pending.isEmpty)
        store.text = "garbage"
        #expect(DurableTelemetryQueue(store: store, cap: 3).pending.isEmpty)
        #expect(DurableTelemetryQueue.isDurable(record))
        #expect(!DurableTelemetryQueue.isDurable(Telemetry.sdkEvent(leg, label: "app_state", event: "x", reason: "background", atEpochMs: 1)))
    }

    // TC-10 (AC-7), the marker part.
    @Test func tc10_callMarkerRoundTrips() {
        let marker = CallMarker(callId: "c-1", channel: "room 1&2", user: "1001", engine: "agora", sdkVersion: "agora-4.6.0", startedAtMs: 42)
        #expect(CallMarker.decode(marker.encode()) == marker)
        #expect(CallMarker.decode("nonsense") == nil)
        #expect(CallMarker.decode(nil) == nil)
        let exit = Telemetry.abnormalExit(marker, exitReason: "unknown", atEpochMs: 9)
        #expect(exit.attributes == ["label": "abnormal_exit", "reason": "abnormal_exit", "event": "abnormal exit", "detail": "exit_reason=unknown",
                                    "call_id": "c-1", "channel": "room 1&2", "leg_uid": "1001", "engine": "agora", "sdk_version": "agora-4.6.0"])
    }

    // TC-13 (AC-9): one app_start per process, no call identity; device fields come from logsJson.
    @Test func tc13_appStartIsAPlainEventWithDeviceFields() {
        let start = Telemetry.appStart(atEpochMs: 5)
        #expect(start.attributes == ["label": "app_start", "reason": "app_start", "event": "app start"])
        let a = attributes(logRecords([start])[0])
        for key in ["platform", "app_version", "os_version", "device_brand", "device_model"] { #expect(a[key] != nil, "\(key)") }
    }
}
