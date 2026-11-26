import Testing
@testable import LtTelemetry

@Test func theRecordHidesTheTestersOwnNetwork() {
    let hops = [TraceHop(ttl: 1, ip: "192.168.1.1", ms: 3), TraceHop(ttl: 2, ip: "10.12.14.251", ms: 4), TraceHop(ttl: 3, ip: "100.64.0.1", ms: 5),
                TraceHop(ttl: 4, ip: "203.0.113.254", ms: 76), TraceHop(ttl: 5, ip: nil, ms: nil)]
    #expect(PathTrace.compact(hops) == "1:private:3;2:private:4;3:private:5;4:203.0.113.254:76;5:*:")
    let record = LabTelemetry.pathTrace(LabTag(runId: "r1", caseId: "SMK-01", role: "A", group: 5),
                                     PathTraceResult(target: "relay", ip: "198.51.100.25", hops: hops, reached: false),
                                     context: TelemetryContext(netType: "wifi"), atEpochMs: 1)
    #expect(record.body == "path_trace" && record.attributes["trace_target"] == "relay" && record.attributes["trace_reached"] == "0")
    #expect(record.attributes["trace_hop_count"] == "5" && record.attributes["test_group"] == "5")
}
