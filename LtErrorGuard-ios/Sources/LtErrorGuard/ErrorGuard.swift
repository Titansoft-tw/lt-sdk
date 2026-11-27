import Foundation

// Decides which handled error events reach the crash reporter (lt-error-guard-spec). SDK-free: the
// Sentry adapter (LtErrorGuardSentry) turns a Sentry event into a `GuardEvent`. Android mirrors it in
// lt-error-guard-android/ErrorGuard.kt; both run lt-error-guard-spec/vectors.

/// One error event as the rules see it.
public struct GuardEvent: Equatable, Sendable {
    /// `module.type` of every exception in the chain (NSError: the domain).
    public var exceptionTypes: [String]
    /// The message and every exception value.
    public var messages: [String]
    /// Stack frames in all exceptions, and how many of them are the app's own.
    public var frames: Int
    public var inAppFrames: Int
    /// fatal / error / warning / info / debug.
    public var level: String
    public var tags: [String: String]
    /// Unhandled: the process or the thread died. Crashes are always kept.
    public var crashed: Bool
    /// Groups events for dedupe; blank = the first exception type, else the first message.
    public var fingerprint: String

    public init(exceptionTypes: [String] = [], messages: [String] = [], frames: Int = 0, inAppFrames: Int = 0, level: String = "error",
                tags: [String: String] = [:], crashed: Bool = false, fingerprint: String = "") {
        self.exceptionTypes = exceptionTypes; self.messages = messages; self.frames = frames; self.inAppFrames = inAppFrames
        self.level = level; self.tags = tags; self.crashed = crashed; self.fingerprint = fingerprint
    }
}

/// `rule`: the rule that decided, `budget` for the session budget, nil when nothing matched (or a crash).
public struct Decision: Equatable, Sendable {
    public let keep: Bool
    public let rule: String?
    public init(keep: Bool, rule: String? = nil) { self.keep = keep; self.rule = rule }
}

/// Events a rule suppressed in this session, reported as app_error (`domain`, `code`, `count`).
public struct Suppressed: Equatable, Sendable {
    public let rule: String
    public let domain: String
    public let code: String
    public let count: Int
    public init(rule: String, domain: String, code: String, count: Int) { self.rule = rule; self.domain = domain; self.code = code; self.count = count }
}

/// Thread-safe: crash reporters call beforeSend from any thread. A session runs from creation (or the last
/// `endSession`) to the next `endSession`; the app picks it (the process, or one call).
public final class ErrorGuard: @unchecked Sendable {
    public static let budget = "budget"
    public static let budgetDomain = "telemetry"
    public static let budgetCode = "error_budget_exceeded"

    /// Read and replaced only under `lock`.
    private var rules: GuardRules
    private let sink: @Sendable (Suppressed) -> Void
    private let random: @Sendable () -> Double
    private let lock = NSLock()
    private var seen = Set<String>()
    private var order: [String] = []
    private var counts: [String: Suppressed] = [:]
    private var kept = 0

    /// `sink` is called once per rule and session, at the first suppressed event (count 1), outside the lock.
    /// `random` is a draw in [0, 1) for action sample.
    public init(rules: GuardRules = .default, sink: @escaping @Sendable (Suppressed) -> Void = { _ in },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.rules = rules; self.sink = sink; self.random = random
    }

    public func decide(_ event: GuardEvent) -> Decision {
        if event.crashed || event.level == "fatal" { return Decision(keep: true) }
        let lower = event.messages.map { $0.lowercased() }
        let (decision, first) = lock.withLock { () -> (Decision, Suppressed?) in
            let rule = rules.rules.first { $0.matches(event, lowerMessages: lower) }
            let keep: Bool
            switch rule?.action {
            case nil, .keep?: keep = true
            case .drop?: keep = false
            case .sample?: keep = random() < rule!.rate
            case .dedupe?: keep = seen.insert(rule!.id + "\u{0}" + key(event)).inserted
            }
            if let rule, !keep { return (Decision(keep: false, rule: rule.id), suppress(rule.id, rule.domain, rule.code)) }
            if let max = rules.maxEvents, kept >= max {
                return (Decision(keep: false, rule: Self.budget), suppress(Self.budget, Self.budgetDomain, Self.budgetCode))
            }
            kept += 1
            return (Decision(keep: true, rule: rule?.id), nil)
        }
        if let first { sink(first) }
        return decision
    }

    /// Replaces the rules (e.g. from `GuardRulesLoader`); the next event uses them. This session's dedupe marks,
    /// budget and counts stay. Crashes stay protected whatever the rules say.
    public func updateRules(_ rules: GuardRules) { lock.withLock { self.rules = rules } }

    /// Every suppression count in this session, in first-seen order.
    public func tallies() -> [Suppressed] { lock.withLock { order.compactMap { counts[$0] } } }

    /// The counts above 1 (the first was already sent through the sink), then a fresh session.
    public func endSession() -> [Suppressed] {
        lock.withLock {
            let totals = order.compactMap { counts[$0] }.filter { $0.count > 1 }
            seen = []; order = []; counts = [:]; kept = 0
            return totals
        }
    }

    /// Returns the first suppression for the sink, or nil when this rule already reported one. Called with the lock held.
    private func suppress(_ rule: String, _ domain: String, _ code: String) -> Suppressed? {
        let key = "\(rule)\u{0}\(domain)\u{0}\(code)"
        let next = counts[key].map { Suppressed(rule: rule, domain: domain, code: code, count: $0.count + 1) }
            ?? Suppressed(rule: rule, domain: domain, code: code, count: 1)
        if counts[key] == nil { order.append(key) }
        counts[key] = next
        return next.count == 1 ? next : nil
    }

    private func key(_ e: GuardEvent) -> String {
        e.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (e.exceptionTypes.first ?? e.messages.first ?? "") : e.fingerprint
    }
}
