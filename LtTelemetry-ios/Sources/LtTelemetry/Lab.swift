import Foundation

// Lab-only records (`case_result`, `net_probe`, `path_trace`); an app without the Lab never calls these.
// Port of lt-telemetry-android lab/LabTelemetry.kt.

/// One hop: the router that answered for this TTL. `ms` is how long the probe took (nil when nothing answered).
public struct TraceHop: Equatable, Sendable {
    public let ttl: Int
    public let ip: String?
    public let ms: Int64?
    public init(ttl: Int, ip: String?, ms: Int64?) { self.ttl = ttl; self.ip = ip; self.ms = ms }
}

public struct PathTraceResult: Equatable, Sendable {
    public let target: String
    public let ip: String
    public let hops: [TraceHop]
    public let reached: Bool
    public init(target: String, ip: String, hops: [TraceHop], reached: Bool) {
        self.target = target; self.ip = ip; self.hops = hops; self.reached = reached
    }
}

/// Encoding of a path trace. Running one (the ICMP socket) stays in the app, as an extension of this enum.
public enum PathTrace {
    /// The phone's own network is not part of the record: private and carrier-grade addresses become "private".
    public static func publicIp(_ ip: String?) -> String {
        guard let ip else { return "*" }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return ip }
        let isPrivate = p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && (64...127).contains(p[1]))
        return isPrivate ? "private" : ip
    }

    /// "ttl:ip:ms" per hop, joined with ";". Silent hops are "ttl:*:".
    public static func compact(_ hops: [TraceHop]) -> String {
        hops.map { "\($0.ttl):\(publicIp($0.ip)):\($0.ms.map { String($0) } ?? "")" }.joined(separator: ";")
    }
}

public enum LabTelemetry {
    public static let caseResult = "case_result"
    public static let netProbe = "net_probe"
    public static let pathTrace = "path_trace"

    /// After a Lab call: the hop-by-hop path from this phone to one known server (the relay or the call's media server).
    public static func pathTrace(_ lab: LabTag, _ result: PathTraceResult, context: TelemetryContext, atEpochMs: Int64) -> TelemetryRecord {
        var a = ["test_run_id": lab.runId, "case_id": lab.caseId, "test_role": lab.role, "trace_target": result.target, "trace_ip": result.ip,
                 "trace_reached": result.reached ? "1" : "0", "trace_hop_count": String(result.hops.count), "trace_hops": PathTrace.compact(result.hops)]
        if lab.group > 0 { a["test_group"] = String(lab.group) }
        for (key, value) in [("net_type", context.netType), ("vpn", context.vpn), ("carrier", context.carrier), ("exit_country", context.exitCountry)] where !value.isEmpty {
            a[key] = value
        }
        return TelemetryRecord(body: pathTrace, atEpochMs: atEpochMs, attributes: a)
    }

    /// Lab lobby check: round trip to each media server (ms, empty when unreachable) and the network it ran on.
    public static func netProbe(_ lab: LabTag, rttMs: [String: Int64?], context: TelemetryContext, atEpochMs: Int64,
                                phase: String = "lobby") -> TelemetryRecord {
        var a = ["test_run_id": lab.runId, "case_id": lab.caseId, "test_role": lab.role, "probe_phase": phase]
        if lab.group > 0 { a["test_group"] = String(lab.group) }
        for (target, ms) in rttMs { a["probe_\(target)_ms"] = ms.map { String($0) } ?? "" }
        for (key, value) in [("net_type", context.netType), ("vpn", context.vpn), ("carrier", context.carrier),
                             ("exit_country", context.exitCountry)] + context.signal.map({ ($0.key, $0.value) }) where !value.isEmpty {
            a[key] = value
        }
        return TelemetryRecord(body: netProbe, atEpochMs: atEpochMs, attributes: a)
    }

    /// The tester's rating after a Lab run (1–5 each). Sent after the call ended, so it carries its own identity.
    public static func caseResult(_ lab: LabTag, engine: String, region: String, clarity: Int, noDrop: Int, atEpochMs: Int64,
                                  valid: Bool = true) -> TelemetryRecord {
        var a = ["test_run_id": lab.runId, "case_id": lab.caseId, "test_role": lab.role, "engine": engine]
        if lab.group > 0 { a["test_group"] = String(lab.group) }
        if !region.isEmpty { a["server_region"] = region }
        a["rating_clarity"] = String(min(max(clarity, 1), 5)); a["rating_drop"] = String(min(max(noDrop, 1), 5))
        // A run the tester marks invalid (setup mistake) stays stored; dashboards leave it out of comparisons.
        a["run_valid"] = valid ? "1" : "0"
        a["env_ok"] = lab.envOk ? "1" : "0"
        return TelemetryRecord(body: caseResult, atEpochMs: atEpochMs, attributes: a)
    }
}
