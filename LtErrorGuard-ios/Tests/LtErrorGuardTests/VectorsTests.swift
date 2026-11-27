import Foundation
import Testing
@testable import LtErrorGuard

// lt-error-guard-spec/vectors, which lt-error-guard-android's VectorsTest runs too.

private let spec = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("lt-error-guard-spec")

private func read(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: spec.appendingPathComponent(name))) as! [String: Any]
}

private func json(_ v: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), as: UTF8.self)
}

private func suppressed(_ v: Any?) -> [Suppressed] {
    (v as? [[String: Any]] ?? []).map {
        Suppressed(rule: $0["rule"] as! String, domain: $0["domain"] as! String, code: $0["code"] as! String, count: $0["count"] as! Int)
    }
}

private func event(_ o: [String: Any]) -> GuardEvent {
    GuardEvent(exceptionTypes: o["exceptionTypes"] as? [String] ?? [], messages: o["messages"] as? [String] ?? [],
               frames: o["frames"] as? Int ?? 0, inAppFrames: o["inAppFrames"] as? Int ?? 0, level: o["level"] as? String ?? "error",
               tags: o["tags"] as? [String: String] ?? [:], crashed: o["crashed"] as? Bool ?? false, fingerprint: o["fingerprint"] as? String ?? "")
}

/// The draw a step sets, read by the guard's `random`.
private final class Draw: @unchecked Sendable { var value = 0.5 }
private final class Sunk: @unchecked Sendable { var items: [Suppressed] = [] }

@Test func decisions() throws {
    for c in try read("vectors/decisions.json")["cases"] as! [[String: Any]] {
        let name = c["name"] as! String
        let rules = c["rules"] as? String == "default" ? GuardRules.default : try GuardRules.parse(json(c["rules"]!))
        let draw = Draw(), sunk = Sunk()
        let guardian = ErrorGuard(rules: rules, sink: { sunk.items.append($0) }, random: { draw.value })
        for (i, step) in (c["steps"] as! [[String: Any]]).enumerated() {
            if let totals = step["endSession"] {
                #expect(guardian.endSession() == suppressed(totals), "\(name) step \(i)")
                continue
            }
            draw.value = (step["random"] as? NSNumber)?.doubleValue ?? 0.5
            let expect = step["expect"] as! [String: Any]
            let want = Decision(keep: expect["keep"] as! Bool, rule: expect["rule"] as? String)
            #expect(guardian.decide(event(step["event"] as! [String: Any])) == want, "\(name) step \(i)")
        }
        if let tallies = c["tallies"] { #expect(guardian.tallies() == suppressed(tallies), "\(name) tallies") }
        if let sink = c["sink"] { #expect(sunk.items == suppressed(sink), "\(name) sink") }
    }
}

@Test func invalidRulesAreRejected() throws {
    for c in try read("vectors/invalid.json")["cases"] as! [[String: Any]] {
        let name = c["name"] as! String, error = c["error"] as! String
        do {
            _ = try GuardRules.parse(json(c["rules"]!))
            Issue.record("\(name): accepted")
        } catch let e as GuardRulesError {
            // Same wording as validate.js, so a field engineer sees one message on every platform.
            #expect(e.description.contains(error), "\(name): \(e)")
        }
    }
}

@Test func theGeneratedDefaultsAreTheSpecFile() throws {
    let file = try String(contentsOf: spec.appendingPathComponent("default-rules.json"), encoding: .utf8)
    #expect(DefaultRules.json == file.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(GuardRules.default.maxEvents == 30)
    #expect(GuardRules.default.rules.count == 4)
}
