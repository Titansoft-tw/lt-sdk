import Foundation

// The rules file (lt-error-guard-spec/rules.schema.json). `parse` rejects what validate.js rejects
// (vectors/invalid.json), so a file checked on a laptop behaves the same on the phone. Android: GuardRules.kt.

enum Action: String, CaseIterable, Sendable { case keep, drop, sample, dedupe }

/// `*` = any run of characters, `?` = exactly one; everything else is literal.
struct Glob: Sendable {
    private let p: [Unicode.Scalar]
    let ignoreCase: Bool

    init(_ pattern: String, ignoreCase: Bool) {
        self.ignoreCase = ignoreCase
        p = Array((ignoreCase ? pattern.lowercased() : pattern).unicodeScalars)
    }

    /// `text` is already lower case when `ignoreCase`.
    func matches(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        var t = 0, g = 0, star = -1, mark = 0
        while t < s.count {
            if g < p.count && (p[g] == "?" || p[g] == s[t]) { t += 1; g += 1 }
            else if g < p.count && p[g] == "*" { star = g; g += 1; mark = t }
            else if star >= 0 { g = star + 1; mark += 1; t = mark }
            else { return false }
        }
        while g < p.count && p[g] == "*" { g += 1 }
        return g == p.count
    }
}

struct GuardRule: Sendable {
    let id: String
    let action: Action
    let rate: Double
    let domain: String
    let code: String
    let exceptionType: [Glob]?
    let message: [Glob]?
    let inApp: Bool?
    let level: Set<String>?
    let tags: [String: [Glob]]?

    /// `lowerMessages` = the event's messages in lower case (message globs ignore case).
    func matches(_ e: GuardEvent, lowerMessages: [String]) -> Bool {
        if let exceptionType, !exceptionType.contains(where: { g in e.exceptionTypes.contains(where: g.matches) }) { return false }
        if let message, !message.contains(where: { g in lowerMessages.contains(where: g.matches) }) { return false }
        if inApp == true && e.inAppFrames <= 0 { return false }
        if inApp == false && !(e.frames > 0 && e.inAppFrames <= 0) { return false }
        if let level, !level.contains(e.level) { return false }
        if let tags, !tags.allSatisfy({ key, globs in e.tags[key].map { v in globs.contains { $0.matches(v) } } ?? false }) { return false }
        return true
    }
}

/// Every problem `GuardRules.parse` found, one per line in `description`.
public struct GuardRulesError: Error, CustomStringConvertible, Sendable {
    public let problems: [String]
    public var description: String { problems.joined(separator: "\n") }
}

public struct GuardRules: Sendable {
    let rules: [GuardRule]
    public let maxEvents: Int?

    /// The rules in lt-error-guard-spec/default-rules.json (the tests check they parse).
    public static let `default`: GuardRules = (try? parse(DefaultRules.json)) ?? GuardRules(rules: [], maxEvents: nil)

    /// Throws `GuardRulesError` listing every problem when `json` is not a valid rules file.
    public static func parse(_ json: String) throws -> GuardRules {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) }
        catch { throw GuardRulesError(problems: ["rules: not JSON (\(error.localizedDescription))"]) }
        var p = Parser()
        guard let o = root as? [String: Any] else { throw GuardRulesError(problems: ["rules: must be an object"]) }
        let parsed = p.rules(o)
        guard p.problems.isEmpty, let parsed else { throw GuardRulesError(problems: p.problems) }
        return parsed
    }
}

/// `[a-z0-9_]+`, plus `-` when `dash` (rule ids).
private func isCode(_ s: String, dash: Bool = false) -> Bool {
    !s.isEmpty && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || (dash && $0 == "-") }
}
private let levels: Set<String> = ["error", "warning", "info", "debug"]

struct Parser {
    var problems: [String] = []

    /// JSONSerialization gives booleans as NSNumber too; tell them apart.
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    static func number(_ v: Any?) -> Double? { isBool(v) ? nil : (v as? NSNumber)?.doubleValue }
    /// A whole number (1 and 1.0 alike, as in JavaScript), else nil.
    static func integer(_ v: Any?) -> Int? {
        guard let d = number(v), d.truncatingRemainder(dividingBy: 1) == 0, abs(d) <= 1e9 else { return nil }
        return Int(d)
    }

    mutating func unknown(_ whereAt: String, _ o: [String: Any], _ allowed: Set<String>) {
        for k in o.keys.sorted() where !allowed.contains(k) { problems.append("\(whereAt): unknown key \(k)") }
    }

    mutating func rules(_ o: [String: Any]) -> GuardRules? {
        unknown("rules", o, ["version", "sessionBudget", "rules"])
        if Self.integer(o["version"]) != 1 { problems.append("version: must be 1") }
        var maxEvents: Int?
        if let raw = o["sessionBudget"] {
            if let b = raw as? [String: Any] {
                unknown("sessionBudget", b, ["maxEvents"])
                maxEvents = Self.integer(b["maxEvents"]).flatMap { $0 >= 1 ? $0 : nil }
                if maxEvents == nil { problems.append("sessionBudget.maxEvents: must be an integer of at least 1") }
            } else { problems.append("sessionBudget: must be an object") }
        }
        guard let list = o["rules"] as? [Any] else { problems.append("rules: must be a list"); return nil }
        var ids = Set<String>()
        let out = list.enumerated().compactMap { i, v in rule(i, v, &ids) }
        return GuardRules(rules: out, maxEvents: maxEvents)
    }

    mutating func rule(_ i: Int, _ v: Any, _ ids: inout Set<String>) -> GuardRule? {
        let r = v as? [String: Any]
        let id = r?["id"] as? String
        let w = "rules[\(i)]" + (id.map { " (\($0))" } ?? "")
        guard let r else { problems.append("\(w): must be an object"); return nil }
        let before = problems.count
        unknown(w, r, ["id", "match", "action", "rate", "domain", "code"])
        if let id, isCode(id, dash: true) {
            if id == "budget" { problems.append("\(w): id budget is reserved for the session budget") }
            else if !ids.insert(id).inserted { problems.append("\(w): duplicate id") }
        } else { problems.append("\(w): id must match [a-z0-9_-]+") }
        let action = (r["action"] as? String).flatMap(Action.init(rawValue:))
        if action == nil { problems.append("\(w): action must be one of \(Action.allCases.map(\.rawValue).joined(separator: ", "))") }
        var rate = 0.0
        if action == .sample {
            if let n = Self.number(r["rate"]), (0...1).contains(n) { rate = n } else { problems.append("\(w): rate must be a number from 0 to 1") }
        } else if r["rate"] != nil { problems.append("\(w): rate is only for action sample") }
        var domain = "", code = ""
        if action == .keep {
            for k in ["domain", "code"] where r[k] != nil { problems.append("\(w): a keep rule has no \(k) (nothing is suppressed)") }
        } else if action != nil {
            domain = r["domain"] as? String ?? ""
            code = r["code"] as? String ?? ""
            if !isCode(domain) { problems.append("\(w): domain must match [a-z0-9_]+") }
            if !isCode(code) { problems.append("\(w): code must match [a-z0-9_]+") }
        }
        guard let m = r["match"] as? [String: Any] else { problems.append("\(w): match must be an object"); return nil }
        unknown("\(w).match", m, ["exceptionType", "message", "inApp", "level", "tags"])
        let exceptionType = m["exceptionType"].flatMap { globs("\(w).match.exceptionType", $0, ignoreCase: false) }
        let message = m["message"].flatMap { globs("\(w).match.message", $0, ignoreCase: true) }
        var inApp: Bool?
        if let raw = m["inApp"] {
            if Self.isBool(raw) { inApp = (raw as? NSNumber)?.boolValue } else { problems.append("\(w).match.inApp: must be true or false") }
        }
        var level: Set<String>?
        if let raw = m["level"] {
            if let l = raw as? [Any], !l.isEmpty, l.allSatisfy({ ($0 as? String).map(levels.contains) ?? false }) {
                level = Set(l.compactMap { $0 as? String })
            } else { problems.append("\(w).match.level: must be a non-empty list of error, warning, info, debug (crashes are always kept)") }
        }
        var tags: [String: [Glob]]?
        if let raw = m["tags"] {
            if let t = raw as? [String: Any], !t.isEmpty {
                var out: [String: [Glob]] = [:]
                for k in t.keys.sorted() { out[k] = globs("\(w).match.tags.\(k)", t[k]!, ignoreCase: false) ?? [] }
                tags = out
            } else { problems.append("\(w).match.tags: must be a non-empty object") }
        }
        guard problems.count == before, let id, let action else { return nil }
        return GuardRule(id: id, action: action, rate: rate, domain: domain, code: code, exceptionType: exceptionType, message: message,
                         inApp: inApp, level: level, tags: tags)
    }

    mutating func globs(_ w: String, _ v: Any, ignoreCase: Bool) -> [Glob]? {
        guard let a = v as? [Any], !a.isEmpty else { problems.append("\(w): must be a non-empty list"); return nil }
        let items = a.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard items.count == a.count else { problems.append("\(w): every glob must be a non-empty string"); return nil }
        return items.map { Glob($0, ignoreCase: ignoreCase) }
    }
}
