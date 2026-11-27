import Foundation
import LtErrorGuard
@testable import LtErrorGuardSentry
import Sentry
import Testing

// The adapter on sentry-cocoa's real Options and Event classes (no SDK started, no network).

private func frame(_ module: String, _ function: String, inApp: Bool?) -> Frame {
    let f = Frame()
    f.module = module; f.function = function; f.inApp = inApp.map { NSNumber(value: $0) }
    return f
}

private func exception(_ module: String?, _ type: String, _ value: String, handled: Bool?, _ frames: [Frame] = []) -> Exception {
    let x = Exception(value: value, type: type)
    x.module = module
    let m = Mechanism(type: "generic")
    m.handled = handled.map { NSNumber(value: $0) }
    x.mechanism = m
    x.stacktrace = SentryStacktrace(frames: frames, registers: [:])
    return x
}

private func event(_ exceptions: [Exception], level: SentryLevel = .error) -> Event {
    let e = Event(level: level)
    e.exceptions = exceptions
    return e
}

@Test func aHandledNetworkErrorBecomesAGuardEvent() {
    let e = event([exception(nil, "NSURLErrorDomain", "Code: -1009", handled: true,
                             [frame("CFNetwork", "load", inApp: false), frame("LtCallDemo", "register()", inApp: true), frame("Foundation", "x", inApp: nil)])],
                  level: .warning)
    e.tags = ["gms": "missing"]
    #expect(SentryGuard.guardEvent(e) == GuardEvent(
        exceptionTypes: ["NSURLErrorDomain"], messages: ["Code: -1009"], frames: 3, inAppFrames: 1, level: "warning",
        tags: ["gms": "missing"], crashed: false, fingerprint: "NSURLErrorDomain|LtCallDemo.register()"))
}

@Test func anUnhandledExceptionIsACrash() {
    #expect(SentryGuard.guardEvent(event([exception(nil, "EXC_BAD_ACCESS", "crash", handled: false)], level: .fatal)).crashed)
}

@Test func aMessageEventGroupsByItsTemplate() {
    let e = Event(level: .info)
    let m = SentryMessage(formatted: "timeout after 3 s")
    m.message = "timeout after %d s"
    e.message = m
    let g = SentryGuard.guardEvent(e)
    #expect(g.messages == ["timeout after 3 s", "timeout after %d s"])
    #expect(g.fingerprint == "timeout after %d s")
    #expect(g.level == "info")
}

private final class Sunk: @unchecked Sendable { var items: [Suppressed] = []; var order: [String] = [] }

@Test func installKeepsTheFirstAndDropsRepeatsWithTheDefaultRules() {
    let sunk = Sunk()
    let options = Options()
    SentryGuard.install(options, guard: ErrorGuard(rules: .default, sink: { sunk.items.append($0) }))
    let net = { event([exception(nil, "NSURLErrorDomain", "Code: -1001", handled: true, [frame("App", "call()", inApp: true)])]) }
    let first = net()
    #expect(options.beforeSend?(first) === first)
    #expect(options.beforeSend?(net()) == nil)
    let crash = event([exception(nil, "NSURLErrorDomain", "Code: -1001", handled: false)], level: .fatal)
    #expect(options.beforeSend?(crash) === crash)
    #expect(sunk.items == [Suppressed(rule: "net-io", domain: "api", code: "http_network", count: 1)])
}

@Test func theAppsOwnBeforeSendRunsFirstAndWhatItDropsIsNotCounted() throws {
    let sunk = Sunk()
    let options = Options()
    options.beforeSend = { e in
        sunk.order.append("app")
        if e.tags?["drop"] == "1" { return nil }
        e.tags = (e.tags ?? [:]).merging(["seen": "1"]) { $1 }
        return e
    }
    let guardian = ErrorGuard(rules: try GuardRules.parse(
        #"{"version": 1, "rules": [{"id": "seen", "match": {"tags": {"seen": ["1"]}}, "action": "dedupe", "domain": "api", "code": "x"}]}"#))
    SentryGuard.install(options, guard: guardian)
    let dropped = Event(level: .error)
    dropped.tags = ["drop": "1"]
    #expect(options.beforeSend?(dropped) == nil)
    #expect(options.beforeSend?(Event(level: .error))?.tags?["seen"] == "1")
    #expect(sunk.order == ["app", "app"])
    #expect(guardian.tallies().isEmpty)
}
