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

@Test func withoutAnInAppFrameTheTopFrameTellsCallSitesApart() {
    let at = { (function: String) in
        event([exception(nil, "NSURLErrorDomain", "Code: -1009", handled: true, [frame("libdispatch", "worker", inApp: nil), frame("X", function, inApp: nil)])])
    }
    #expect(SentryGuard.guardEvent(at("a()")).fingerprint == "NSURLErrorDomain|X.a()")
    #expect(SentryGuard.guardEvent(at("b()")).fingerprint == "NSURLErrorDomain|X.b()")
}

@Test func unsymbolicatedFramesAreGroupedByTheWholeStack() {
    func f(_ address: String) -> Frame {
        let x = Frame()
        x.package = "/private/var/containers/Bundle/Application/X/App.app/App"
        x.imageAddress = "0x0000000100000000"; x.instructionAddress = address; x.inApp = true
        return x
    }
    let at = { (caller: String) in event([exception(nil, "NSURLErrorDomain", "Code: -1009", handled: true, [f(caller), f("0x0000000100000400")])]) }
    let a = SentryGuard.guardEvent(at("0x0000000100000100")).fingerprint
    #expect(a.hasPrefix("NSURLErrorDomain|stack:"))
    #expect(a == SentryGuard.guardEvent(at("0x0000000100000100")).fingerprint)
    #expect(a != SentryGuard.guardEvent(at("0x0000000100000200")).fingerprint, "same top frame, different caller")
}

@Test func withoutExceptionFramesTheCurrentThreadIsUsed() {
    let e = event([exception(nil, "NSURLErrorDomain", "Code: -1009", handled: true)])
    let other = SentryThread(threadId: 1)
    other.stacktrace = SentryStacktrace(frames: [frame("Other", "idle()", inApp: true)], registers: [:])
    let current = SentryThread(threadId: 2)
    current.current = true
    current.stacktrace = SentryStacktrace(frames: [frame("UIKit", "run", inApp: false), frame("App", "load()", inApp: true)], registers: [:])
    e.threads = [other, current]
    let g = SentryGuard.guardEvent(e)
    #expect(g.frames == 2)
    #expect(g.inAppFrames == 1)
    #expect(g.fingerprint == "NSURLErrorDomain|App.load()")
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

/// The guard's decision on events the real SDK built (capture(error:) through SentryClient), with nothing sent.
private final class Recorder: @unchecked Sendable {
    var events: [(GuardEvent, Bool)] = []
    var appCalls = 0
}

@inline(never) private func failAtSiteA() { SentrySDK.capture(error: NSError(domain: NSURLErrorDomain, code: -1009)) }
@inline(never) private func failAtSiteB() { SentrySDK.capture(error: NSError(domain: NSURLErrorDomain, code: -1001)) }

private func start(_ configure: @escaping (Options) -> Void) {
    SentrySDK.start { options in
        options.dsn = "https://00000000000000000000000000000000@o0.ingest.sentry.io/0"
        options.enableCrashHandler = false
        options.enableAutoSessionTracking = false
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        // Otherwise other suites' HTTP 5xx in this process (LtTelemetry's transport tests) arrive as HTTPClientError events.
        options.enableCaptureFailedRequests = false
        configure(options)
    }
    // Off the main thread, start finishes on the main queue; capture before that is ignored.
    for _ in 0..<100 where !SentrySDK.isEnabled { Thread.sleep(forTimeInterval: 0.05) }
}

@Suite(.serialized) struct RealSdkEvents {
    @Test func capturedErrorsCarryTheirStackAndDedupePerCallSite() {
        let rec = Recorder()
        start { options in
            options.beforeSend = { e in rec.appCalls += 1; return e }
            SentryGuard.install(options, guard: ErrorGuard(rules: .default))
            let installed = options.beforeSend
            options.beforeSend = { e in rec.events.append((SentryGuard.guardEvent(e), installed?(e) != nil)); return nil }
        }
        defer { SentrySDK.close() }
        #expect(SentrySDK.isEnabled)
        for _ in 0..<2 { failAtSiteA() } // one call site twice, as a retry loop would
        failAtSiteB()
        #expect(rec.appCalls == 3)
        #expect(rec.events.count == 3)
        guard rec.events.count == 3 else { return }
        let (a1, keptA1) = rec.events[0], (a2, keptA2) = rec.events[1], (b, keptB) = rec.events[2]
        #expect(a1.frames > 0, "capture(error:) has its stack on the current thread")
        #expect(a1.exceptionTypes == ["NSURLErrorDomain"])
        #expect(a1.fingerprint.hasPrefix("NSURLErrorDomain|stack:") && a1.fingerprint == a2.fingerprint, "\(a1.fingerprint) / \(a2.fingerprint)")
        #expect(a1.fingerprint != b.fingerprint, "two call sites: \(a1.fingerprint) / \(b.fingerprint)")
        #expect(keptA1 && !keptA2 && keptB)
    }

    @Test func anAppUsingBeforeSendWithHintIsStillGuarded() throws {
        let probe = Options()
        guard probe.responds(to: NSSelectorFromString(SentryGuard.withHintKey)) else { return } // sentry-cocoa 8.x has no such callback
        let rec = Recorder()
        start { options in
            let app: SentryGuard.WithHint = { e, _ in rec.appCalls += 1; return e }
            options.setValue(app, forKey: SentryGuard.withHintKey)
            SentryGuard.install(options, guard: ErrorGuard(rules: .default))
            let installed = unsafeBitCast(options.value(forKey: SentryGuard.withHintKey) as AnyObject?, to: SentryGuard.WithHint.self)
            let recorder: SentryGuard.WithHint = { e, hint in rec.events.append((SentryGuard.guardEvent(e), installed(e, hint) != nil)); return nil }
            options.setValue(recorder, forKey: SentryGuard.withHintKey)
            #expect(options.beforeSend == nil)
        }
        defer { SentrySDK.close() }
        #expect(SentrySDK.isEnabled)
        for _ in 0..<2 { failAtSiteA() }
        #expect(rec.appCalls == 2)
        #expect(rec.events.map(\.1) == [true, false])
    }
}
