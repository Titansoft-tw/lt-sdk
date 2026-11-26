import Testing
@testable import LtTelemetry

// Port of lt-call-demo LabTests.swift (the record parts).

@Test func caseResultCarriesRatingsValidityAndEnvironment() {
    let r = LabTelemetry.caseResult(LabTag(runId: "r1", caseId: "NET-03", role: "B", group: 4, envOk: false), engine: "agora",
                                 region: "", clarity: 9, noDrop: 0, atEpochMs: 1, valid: false)
    #expect(r.body == "case_result")
    #expect(r.attributes["rating_clarity"] == "5" && r.attributes["rating_drop"] == "1")
    #expect(r.attributes["run_valid"] == "0" && r.attributes["env_ok"] == "0" && r.attributes["test_group"] == "4")
    #expect(r.attributes["server_region"] == nil)
}


@Test func exitCountryExtrasAndTheLobbyProbeAreSent() {
    let ctx = TelemetryContext(netType: "wifi", vpn: "1", exitCountry: "JP", signal: ["low_data_mode": "0"])
    let leg = TelemetryLeg(callId: "c", channel: "t1", user: "1", engine: "agora")
    var m = AudioMetrics()
    m.extra = ["agora_mic_volume": "120"]
    let a = Telemetry.qualitySecond(leg, m, atEpochMs: 1, context: ctx).attributes
    #expect(a["exit_country"] == "JP" && a["low_data_mode"] == "0" && a["agora_mic_volume"] == "120")
    let probe = LabTelemetry.netProbe(LabTag(runId: "r1", caseId: "SMK-01", role: "A", group: 2), rttMs: ["tw": 18, "us": nil], context: ctx, atEpochMs: 1)
    #expect(probe.body == "net_probe" && probe.attributes["probe_tw_ms"] == "18" && probe.attributes["probe_us_ms"] == "")
    #expect(probe.attributes["test_group"] == "2" && probe.attributes["exit_country"] == "JP")
}

@Test func sessionTimeAndProbePhaseAreSeparateAttributes() {
    let leg = TelemetryLeg(callId: "c", channel: "t1", user: "1", engine: "agora")
    let setup = Telemetry.callSetup(leg, .tokenOk, detail: "", atEpochMs: 5, extra: ["session_ms": "212"]).attributes
    #expect(setup["reason"] == "token_ok" && setup["session_ms"] == "212")
    let tag = LabTag(runId: "r1", caseId: "SMK-01", role: "A", group: 2)
    let ctx = TelemetryContext()
    #expect(LabTelemetry.netProbe(tag, rttMs: ["relay": 30], context: ctx, atEpochMs: 1).attributes["probe_phase"] == "lobby")
    let mid = LabTelemetry.netProbe(tag, rttMs: ["relay": 31], context: ctx, atEpochMs: 2, phase: "in_call").attributes
    #expect(mid["probe_phase"] == "in_call" && mid["probe_relay_ms"] == "31")
}
