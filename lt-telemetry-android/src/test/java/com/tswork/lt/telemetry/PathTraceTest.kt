package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.*
import com.tswork.lt.telemetry.lab.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PathTraceTest {
    @Test fun theRecordHidesTheTestersOwnNetwork() {
        val hops = listOf(TraceHop(1, "192.168.1.1", 3), TraceHop(2, "10.12.14.251", 4), TraceHop(3, "100.64.0.1", 5),
            TraceHop(4, "203.0.113.254", 76), TraceHop(5, null, null))
        assertEquals("1:private:3;2:private:4;3:private:5;4:203.0.113.254:76;5:*:", PathTrace.compact(hops))
        val rec = LabTelemetry.pathTrace(LabTag("r1", "SMK-01", "A", 5), PathTraceResult("relay", "198.51.100.25", hops, false), TelemetryContext(netType = "wifi"), 1)
        assertEquals("path_trace", rec.body); assertEquals("relay", rec.attributes["trace_target"]); assertEquals("0", rec.attributes["trace_reached"])
        assertEquals("5", rec.attributes["trace_hop_count"]); assertEquals("5", rec.attributes["test_group"])
    }
}
