import Foundation
import Testing
@testable import LtTelemetry

/// Remote telemetry config (schema 1): defaults, clamps, rules, rollout, and files that must be ignored. Same cases as
/// Android's RemoteTelemetryConfigTest.
struct RemoteTelemetryConfigTests {
    private let ios = ConfigTarget(platform: "ios", appVersion: "1.4.2", build: "release")

    @Test func anEmptyTelemetryBlockGivesTheDefaultsWithAVersion() throws {
        var expected = TelemetrySettings()
        expected.version = 3
        #expect(RemoteTelemetryConfig.parse(#"{"schema":1,"version":3}"#, target: ios, bucket: 0) == expected)
    }

    @Test func valuesAreClampedToSafeRanges() throws {
        let s = try #require(RemoteTelemetryConfig.parse(#"""
            {"schema":1,"version":1,"telemetry":{"enabled":false,"quality_every_s":0,"call_sample_percent":250,"batch_records":999,
             "retry_base_s":1,"retry_max_s":2,"queue_max_kb":1,"queue_max_age_h":99999,"drop_labels":["mic","",5,"fgs"],"x":{"y":[1]}}}
            """#, target: ios, bucket: 0))
        #expect(!s.enabled)
        #expect(s.qualityEverySec == 1)
        #expect(s.callSamplePercent == 100)
        #expect(s.batchRecords == 30)
        #expect(s.retryBaseMs == 5_000 && s.retryMaxMs == 5_000)
        #expect(s.queueMaxBytes == 512 * 1024)
        #expect(s.queueMaxAgeMs == 720 * 3_600_000)
        #expect(s.dropLabels == ["mic", "fgs"])
    }

    @Test func numbersAreNotBooleansAndBooleansAreNotNumbers() throws {
        let s = try #require(RemoteTelemetryConfig.parse(#"{"schema":1,"version":1,"telemetry":{"enabled":0,"batch_records":true}}"#,
                                                         target: ios, bucket: 0))
        #expect(s.enabled) // 0 is not false.
        #expect(s.batchRecords == 3) // true is not 1.
    }

    @Test func rulesApplyInOrderByPlatformBuildAndVersionRange() throws {
        let json = #"""
            {"schema":1,"version":7,"telemetry":{"quality_every_s":1},"rules":[
             {"match":{"platform":"ios"},"telemetry":{"quality_every_s":2,"batch_records":5}},
             {"match":{"platform":"android"},"telemetry":{"quality_every_s":9}},
             {"match":{"app_version_min":"1.4.0","app_version_below":"1.5.0"},"telemetry":{"quality_every_s":3}},
             {"match":{"build":"debug"},"telemetry":{"enabled":false}}]}
            """#
        let s = try #require(RemoteTelemetryConfig.parse(json, target: ios, bucket: 0))
        #expect(s.qualityEverySec == 3 && s.batchRecords == 5 && s.enabled)
        #expect(RemoteTelemetryConfig.parse(json, target: ConfigTarget(platform: "ios", appVersion: "1.5.0", build: "release"), bucket: 0)?.qualityEverySec == 2)
        #expect(RemoteTelemetryConfig.parse(json, target: ConfigTarget(platform: "ios", appVersion: "1.4.2", build: "debug"), bucket: 0)?.enabled == false)
        #expect(RemoteTelemetryConfig.parse(json, target: ConfigTarget(platform: "android", appVersion: "2.0", build: "release"), bucket: 0)?.qualityEverySec == 9)
    }

    @Test func rolloutUsesTheLocalBucket() {
        let json = #"{"schema":1,"version":2,"rules":[{"rollout_percent":10,"telemetry":{"quality_every_s":5}}]}"#
        #expect(RemoteTelemetryConfig.parse(json, target: ios, bucket: 9)?.qualityEverySec == 5)
        #expect(RemoteTelemetryConfig.parse(json, target: ios, bucket: 10)?.qualityEverySec == 1)
    }

    @Test func unusableFilesAreIgnored() {
        for bad in ["", "not json", "[]", #"{"version":1}"#, #"{"schema":2,"version":1}"#, #"{"schema":1}"#,
                    #"{"schema":1,"version":1.5}"#, #"{"schema":1,"version":true}"#, #"{"schema":1,"version":1} trailing"#] {
            #expect(RemoteTelemetryConfig.parse(bad, target: ios, bucket: 0) == nil, "\(bad)")
        }
    }

    @Test func versionsCompareNumerically() {
        #expect(RemoteTelemetryConfig.compareVersions("1.10.0", "1.9") > 0)
        #expect(RemoteTelemetryConfig.compareVersions("1.4", "1.4.0") == 0)
        #expect(RemoteTelemetryConfig.compareVersions("1.4.0-debug", "1.4.0") == 0)
        #expect(RemoteTelemetryConfig.compareVersions("1.3.9", "1.4.0") < 0)
    }

    @Test func qualitySamplingFollowsEveryNAndThePerCallSample() {
        var s = TelemetrySettings()
        s.qualityEverySec = 3
        s.batchRecords = 5
        var every3 = QualitySampling(s, roll: 0)
        let taken = (1...7).map { _ in every3.take() }
        #expect(taken == [true, false, false, true, false, false, true])
        #expect(every3.batch == 5)
        var half = TelemetrySettings()
        half.callSamplePercent = 50
        var inside = QualitySampling(half, roll: 49)
        let first = inside.take()
        #expect(first)
        var out = QualitySampling(half, roll: 50)
        #expect(!out.sendsQuality)
        let anyTaken = (1...5).contains { _ in out.take() }
        #expect(!anyTaken)
    }
}
