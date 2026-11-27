import Foundation
import Testing
@testable import LtErrorGuard

// What the vectors cannot show: threads, re-entrant sinks, the matcher's corners.

private let net = """
{"version": 1, "sessionBudget": {"maxEvents": 50}, "rules": [
 {"id": "net", "match": {"exceptionType": ["java.net.*"]}, "action": "dedupe", "domain": "api", "code": "http_network"}]}
"""

@Test func concurrentEventsKeepTheBudgetAndCountsExact() async throws {
    let guardian = ErrorGuard(rules: try GuardRules.parse(net))
    let kept = await withTaskGroup(of: Int.self) { group in
        for t in 0..<8 {
            group.addTask {
                var n = 0
                for i in 0..<1000 {
                    let e = i % 2 == 0 ? GuardEvent(exceptionTypes: ["java.net.UnknownHostException"], fingerprint: "f\(i % 10)")
                        : GuardEvent(messages: ["thread \(t) event \(i)"])
                    if guardian.decide(e).keep { n += 1 }
                }
                return n
            }
        }
        return await group.reduce(0, +)
    }
    #expect(kept == 50)
    #expect(guardian.tallies().reduce(0) { $0 + $1.count } == 8000 - 50)
}

private final class Box: @unchecked Sendable { var guardian: ErrorGuard?; var seen: [Suppressed] = [] }

@Test func aSinkMayCallBackIntoTheGuard() throws {
    let box = Box()
    box.guardian = ErrorGuard(rules: try GuardRules.parse(net), sink: { first in
        box.seen.append(first)
        _ = box.guardian?.tallies()
        _ = box.guardian?.decide(GuardEvent(messages: ["from sink"]))
    })
    let e = GuardEvent(exceptionTypes: ["java.net.ConnectException"])
    #expect(box.guardian!.decide(e).keep)
    #expect(!box.guardian!.decide(e).keep)
    #expect(box.seen == [Suppressed(rule: "net", domain: "api", code: "http_network", count: 1)])
}

@Test func globCorners() {
    func m(_ p: String, _ t: String) -> Bool { Glob(p, ignoreCase: false).matches(t) }
    #expect(m("*", ""))
    #expect(m("**a**", "a"))
    #expect(m("a*b*c", "aXbYbZc"))
    #expect(!m("a*b*c", "aXbYbZ"))
    #expect(m("?", "x"))
    #expect(!m("?", ""))
    #expect(m("[a]+", "[a]+"))
    #expect(!m("a", "A"))
    #expect(Glob("*NOT_AVAILABLE*", ignoreCase: true).matches("service_not_available"))
}

@Test func parseReportsEveryProblemAtOnce() {
    #expect {
        try GuardRules.parse(#"{"version": 2, "rules": [{"id": "A", "match": {}, "action": "x"}]}"#)
    } throws: { e in
        let p = (e as! GuardRulesError).problems
        return p.contains { $0.contains("version") } && p.contains { $0.contains("id must") } && p.contains { $0.contains("action") }
    }
}

@Test func notJsonIsRejected() {
    #expect(throws: GuardRulesError.self) { try GuardRules.parse("{") }
    #expect(throws: GuardRulesError.self) { try GuardRules.parse("") }
}

@Test func integralNumbersAreIntegersButBooleansAreNot() throws {
    #expect(try GuardRules.parse(#"{"version": 1.0, "sessionBudget": {"maxEvents": 3.0}, "rules": []}"#).maxEvents == 3)
    #expect(throws: GuardRulesError.self) { try GuardRules.parse(#"{"version": true, "rules": []}"#) }
    #expect(throws: GuardRulesError.self) {
        try GuardRules.parse(#"{"version": 1, "rules": [{"id": "s", "match": {}, "action": "sample", "rate": true, "domain": "api", "code": "x"}]}"#)
    }
}

@Test func updateRulesKeepsTheSessionAndStillProtectsCrashes() throws {
    let guardian = ErrorGuard(rules: try GuardRules.parse(net))
    let e = GuardEvent(exceptionTypes: ["java.net.ConnectException"])
    #expect(guardian.decide(e).keep)
    guardian.updateRules(try GuardRules.parse(#"{"version": 1, "rules": [{"id": "net", "match": {}, "action": "dedupe", "domain": "api", "code": "http_network"}]}"#))
    #expect(!guardian.decide(e).keep)
    guardian.updateRules(try GuardRules.parse(#"{"version": 1, "rules": [{"id": "all", "match": {}, "action": "drop", "domain": "api", "code": "x"}]}"#))
    #expect(guardian.decide(GuardEvent(crashed: true)).keep)
    #expect(guardian.tallies() == [Suppressed(rule: "net", domain: "api", code: "http_network", count: 1)])
}

@Test func theDefaultSampleDrawIsInRange() throws {
    let guardian = ErrorGuard(rules: try GuardRules.parse(
        #"{"version": 1, "rules": [{"id": "half", "match": {}, "action": "sample", "rate": 0.5, "domain": "api", "code": "x"}]}"#))
    let kept = (1...2000).filter { _ in guardian.decide(GuardEvent()).keep }.count
    #expect((800...1200).contains(kept), "kept \(kept) of 2000")
}
