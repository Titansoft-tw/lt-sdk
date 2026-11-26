import Testing
@testable import LtTelemetry

// The SDK's own enums against the generated contract, and the pure push / CallKit / MetricKit rules
// (lt-call-demo tested these through CallController in Phase2TelemetryTests).

@Test func enumsMatchTheContract() {
    #expect(ErrorDomain.allCases.map(\.rawValue) == Contract.errorDomains)
    #expect(SetupStage.allCases.map(\.rawValue) == Contract.appSetupStages)
    #expect(MicEvent.allCases.map(\.reason) == Contract.labels["mic"])
    #expect([Severity.info, Severity.warn, Severity.error, Severity.fatal] == Contract.severities)
    #expect((0...3).map(Thermal.name) == Contract.thermalLevels)
    for body in [Telemetry.qualitySecond, Telemetry.sdkEvent, Telemetry.appErrorBody, LabTelemetry.caseResult, LabTelemetry.netProbe,
                 LabTelemetry.pathTrace] {
        #expect(Contract.bodies.contains(body), "\(body)")
    }
}

@Test func contextBuildsFromTheDeviceInfoReaders() {
    let net = NetworkSnapshot(netType: "4g", netTypeOs: "4g", carrier: "", country: "", vpn: "0", exitCountry: "TW",
                              signal: ["low_data_mode": "0"], radio: "CTRadioAccessTechnologyLTE")
    let c = TelemetryContext(net, AudioRoute(route: "bluetooth", device: "AirPods", btProfile: "hfp"), DeviceState(batteryPct: 50), netTypeSdk: "4g")
    #expect(c == TelemetryContext(netType: "4g", audioRoute: "bluetooth", audioDevice: "AirPods", btProfile: "hfp", vpn: "0", netTypeOs: "4g",
                                  netTypeSdk: "4g", exitCountry: "TW", signal: ["low_data_mode": "0"], radio: "CTRadioAccessTechnologyLTE",
                                  device: DeviceState(batteryPct: 50)))
}

@Test func secretAttributesUseTheContractPattern() {
    for name in ["media_key", "apiKey", "token", "turn_credential", "client_secret", "private_key", "safety_code", "ticket", "sdp", "Authorization"] {
        #expect(Telemetry.isSecretAttribute(name), "\(name)")
    }
    for name in ["call_id", "label", "rtt_ms", "platform", "sdk_version"] { #expect(!Telemetry.isSecretAttribute(name), "\(name)") }
}

@Test func pushErrorsFollowTheContract() {
    #expect(PushErrors.register(status: 204) == nil)
    #expect(PushErrors.register(status: 501) == nil) // Push not configured on the relay: expected.
    #expect(PushErrors.register(status: 503)?.code == "http_503")
    #expect(PushErrors.tokenUnavailable("empty").code == "push_token_register_failed")
    #expect(PushErrors.callKitReportFailed("x").domain == .push)
    let audio = PushErrors.callKitAudioNotActivated(afterMs: 5_200)
    #expect(audio.domain == .audio && audio.code == "callkit_audio_not_activated" && audio.detail == "no didActivate 5 s after answer")
}

@Test func callKitAudioWatchFiresOnceAfterFiveSeconds() {
    var watch = CallKitAudioWatch()
    watch.answer(atMs: 1_000)
    let early = watch.overdue(nowMs: 5_999), due = watch.overdue(nowMs: 6_000), again = watch.overdue(nowMs: 9_000)
    #expect(!early && due && !again) // Once.
    watch.answer(atMs: 10_000); watch.activate()
    let activated = watch.overdue(nowMs: 20_000)
    #expect(!activated)
    watch.answer(atMs: 30_000); watch.end()
    let ended = watch.overdue(nowMs: 40_000)
    #expect(!ended && !watch.answered)
}

@Test func metricKitHangsCrashesAndDailyExits() {
    let diagnostics = MetricKitDiagnostics(hangsMs: [2_350], crashes: ["exception=EXC_BAD_ACCESS signal=11"])
    let withSentry = MetricKitReport.errors(diagnostics, sentryEnabled: true)
    #expect(withSentry.map(\.code) == ["hang"] && withSentry[0].severity == "WARN" && withSentry[0].detail == "hang_ms=2350")
    let without = MetricKitReport.errors(diagnostics, sentryEnabled: false)
    #expect(without.map(\.code) == ["hang", "crash"] && without[1].severity == "FATAL" && without[1].fatal)
    let exits = MetricKitExits(foreground: ["cumulativeNormalAppExitCount": 4], background: ["cumulativeCPUResourceLimitExitCount": 3],
                               periodStartMs: 1_700_000_000_000, periodEndMs: 1_700_086_400_000)
    let a = MetricKitReport.dailyExits(exits, atEpochMs: 1).attributes
    #expect(a["label"] == "app_exit_daily" && a["fg_normal_app_exit"] == "4" && a["bg_cpu_resource_limit_exit"] == "3")
    #expect(a["period_start"] == "1700000000000" && a["period_end"] == "1700086400000" && a["call_id"] == nil)
    #expect(MetricKitReport.exitName("cumulativeBadAccessExitCount") == "bad_access_exit")
    #expect(MetricKitReport.exitName("cumulativeIllegalInstructionExitCount") == "illegal_instruction_exit")
}
