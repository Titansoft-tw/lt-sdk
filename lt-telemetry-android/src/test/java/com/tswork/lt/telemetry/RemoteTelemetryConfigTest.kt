package com.tswork.lt.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Remote telemetry config (schema 1): defaults, clamps, rules, rollout, and files that must be ignored. */
class RemoteTelemetryConfigTest {
    private val android = ConfigTarget("android", "1.4.2", "release")

    @Test fun anEmptyTelemetryBlockGivesTheDefaultsWithAVersion() {
        val s = RemoteTelemetryConfig.parse("""{"schema":1,"version":3}""", android, 0)!!
        assertEquals(TelemetrySettings(version = 3), s)
    }

    @Test fun valuesAreClampedToSafeRanges() {
        val s = RemoteTelemetryConfig.parse("""{"schema":1,"version":1,"telemetry":{"enabled":false,"quality_every_s":0,
            "call_sample_percent":250,"batch_records":999,"retry_base_s":1,"retry_max_s":2,"queue_max_kb":1,"queue_max_age_h":99999,
            "drop_labels":["mic","",5,"fgs"],"unknown_field":{"x":[1,2]}}}""", android, 0)!!
        assertFalse(s.enabled)
        assertEquals(1, s.qualityEverySec)
        assertEquals(100, s.callSamplePercent)
        assertEquals(30, s.batchRecords)
        assertEquals(5_000L, s.retryBaseMs)
        assertEquals(5_000L, s.retryMaxMs) // Never below the base.
        assertEquals(512L * 1024, s.queueMaxBytes)
        assertEquals(720L * 3_600_000, s.queueMaxAgeMs)
        assertEquals(setOf("mic", "fgs"), s.dropLabels)
    }

    @Test fun rulesApplyInOrderByPlatformBuildAndVersionRange() {
        val json = """{"schema":1,"version":7,"telemetry":{"quality_every_s":1},"rules":[
            {"match":{"platform":"android"},"telemetry":{"quality_every_s":2,"batch_records":5}},
            {"match":{"platform":"ios"},"telemetry":{"quality_every_s":9}},
            {"match":{"app_version_min":"1.4.0","app_version_below":"1.5.0"},"telemetry":{"quality_every_s":3}},
            {"match":{"build":"debug"},"telemetry":{"enabled":false}}]}"""
        val s = RemoteTelemetryConfig.parse(json, android, 0)!!
        assertEquals(3, s.qualityEverySec) // Later rules win.
        assertEquals(5, s.batchRecords)
        assertTrue(s.enabled)
        assertEquals(2, RemoteTelemetryConfig.parse(json, android.copy(appVersion = "1.5.0"), 0)!!.qualityEverySec)
        assertFalse(RemoteTelemetryConfig.parse(json, android.copy(build = "debug"), 0)!!.enabled)
        assertEquals(9, RemoteTelemetryConfig.parse(json, ConfigTarget("ios", "2.0", "release"), 0)!!.qualityEverySec)
    }

    @Test fun rolloutUsesTheLocalBucket() {
        val json = """{"schema":1,"version":2,"rules":[{"rollout_percent":10,"telemetry":{"quality_every_s":5}}]}"""
        assertEquals(5, RemoteTelemetryConfig.parse(json, android, 9)!!.qualityEverySec)
        assertEquals(1, RemoteTelemetryConfig.parse(json, android, 10)!!.qualityEverySec)
    }

    @Test fun unusableFilesAreIgnored() {
        for (bad in listOf("", "not json", "[]", """{"version":1}""", """{"schema":2,"version":1}""", """{"schema":1}""",
            """{"schema":1,"version":1.5}""", """{"schema":1,"version":1} trailing""")) {
            assertNull(bad, RemoteTelemetryConfig.parse(bad, android, 0))
        }
    }

    @Test fun versionsCompareNumerically() {
        assertTrue(RemoteTelemetryConfig.compareVersions("1.10.0", "1.9") > 0)
        assertEquals(0, RemoteTelemetryConfig.compareVersions("1.4", "1.4.0"))
        assertEquals(0, RemoteTelemetryConfig.compareVersions("1.4.0-debug", "1.4.0"))
        assertTrue(RemoteTelemetryConfig.compareVersions("1.3.9", "1.4.0") < 0)
    }

    @Test fun qualitySamplingFollowsEveryNAndThePerCallSample() {
        val every3 = QualitySampling(TelemetrySettings(qualityEverySec = 3, batchRecords = 5), roll = 0)
        assertEquals(listOf(true, false, false, true, false, false, true), (1..7).map { every3.take() })
        assertEquals(5, every3.batch)
        val half = TelemetrySettings(callSamplePercent = 50)
        assertTrue(QualitySampling(half, roll = 49).take())
        val out = QualitySampling(half, roll = 50)
        assertFalse(out.sendsQuality)
        assertFalse((1..5).any { out.take() })
        assertFalse(QualitySampling(TelemetrySettings(callSamplePercent = 0), roll = 0).take())
    }

    @Test fun miniJsonReadsEscapesAndNesting() {
        assertEquals(mapOf("a" to listOf(1.0, true, null, "x\"\né"), "b" to mapOf<String, Any?>()),
            MiniJson.parse("""{"a":[1,true,null,"x\"\né"],"b":{}}"""))
    }
}
