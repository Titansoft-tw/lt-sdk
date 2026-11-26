package com.tswork.lt.telemetry.lab

import com.tswork.lt.telemetry.LabTag
import com.tswork.lt.telemetry.TelemetryContext
import com.tswork.lt.telemetry.TelemetryRecord

/** One hop: the router that answered for this TTL. [ms] is ping's own time for the target; for a router on the way, how long the probe took: an upper bound that includes starting ping, so never compare the two. */
data class TraceHop(val ttl: Int, val ip: String?, val ms: Long?)

data class PathTraceResult(val target: String, val ip: String, val hops: List<TraceHop>, val reached: Boolean)

/** Encoding of a path trace. Running one (the system `ping`) stays in the app. */
object PathTrace {
    /** The phone's own network is not part of the record: private and carrier-grade addresses become "private". */
    fun publicIp(ip: String?): String {
        if (ip == null) return "*"
        val p = ip.split(".").mapNotNull { it.toIntOrNull() }
        val private = p.size == 4 && (p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31) ||
            (p[0] == 169 && p[1] == 254) || (p[0] == 100 && p[1] in 64..127))
        return if (private) "private" else ip
    }

    /** "ttl:ip:ms" per hop, joined with ";". Silent hops are "ttl:*:". */
    fun compact(hops: List<TraceHop>) = hops.joinToString(";") { "${it.ttl}:${publicIp(it.ip)}:${it.ms ?: ""}" }
}

/** Lab-only records (`case_result`, `net_probe`, `path_trace`); an app without the Lab never calls these. */
object LabTelemetry {
    const val CASE_RESULT = "case_result"
    const val NET_PROBE = "net_probe"
    const val PATH_TRACE = "path_trace"

    /** After a Lab call: the hop-by-hop path from this phone to one known server (the relay or the call's media server). */
    fun pathTrace(lab: LabTag, result: PathTraceResult, context: TelemetryContext, atEpochMs: Long) =
        TelemetryRecord(PATH_TRACE, atEpochMs, buildMap {
            put("test_run_id", lab.runId); put("case_id", lab.caseId); put("test_role", lab.role)
            if (lab.group > 0) put("test_group", lab.group.toString())
            put("trace_target", result.target); put("trace_ip", result.ip)
            put("trace_reached", if (result.reached) "1" else "0")
            put("trace_hop_count", result.hops.size.toString())
            put("trace_hops", PathTrace.compact(result.hops))
            for ((key, value) in listOf("net_type" to context.netType, "vpn" to context.vpn, "carrier" to context.carrier,
                "exit_country" to context.exitCountry)) if (value.isNotBlank()) put(key, value)
        })

    /** Lab lobby check: round trip to each media server (ms, blank when unreachable) and the network it ran on. */
    fun netProbe(lab: LabTag, rttMs: Map<String, Long?>, context: TelemetryContext, atEpochMs: Long, phase: String = "lobby") =
        TelemetryRecord(NET_PROBE, atEpochMs, buildMap {
            put("probe_phase", phase)
            put("test_run_id", lab.runId); put("case_id", lab.caseId); put("test_role", lab.role)
            if (lab.group > 0) put("test_group", lab.group.toString())
            for ((target, ms) in rttMs) put("probe_${target}_ms", ms?.toString() ?: "")
            for ((key, value) in listOf("net_type" to context.netType, "vpn" to context.vpn, "carrier" to context.carrier,
                "exit_country" to context.exitCountry) + context.signal.toList()) if (value.isNotBlank()) put(key, value)
        })

    /** The tester's rating after a Lab run (1–5 each). Sent after the call ended, so it carries its own identity. */
    fun caseResult(lab: LabTag, engine: String, region: String, clarity: Int, noDrop: Int, atEpochMs: Long, valid: Boolean = true) =
        TelemetryRecord(CASE_RESULT, atEpochMs, buildMap {
            put("test_run_id", lab.runId); put("case_id", lab.caseId); put("test_role", lab.role); put("engine", engine)
            if (lab.group > 0) put("test_group", lab.group.toString())
            if (region.isNotBlank()) put("server_region", region)
            put("rating_clarity", clarity.coerceIn(1, 5).toString()); put("rating_drop", noDrop.coerceIn(1, 5).toString())
            // A run the tester marks invalid (setup mistake) stays stored; dashboards leave it out of comparisons.
            put("run_valid", if (valid) "1" else "0")
            put("env_ok", if (lab.envOk) "1" else "0")
        })
}
