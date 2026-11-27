import Foundation
import LtErrorGuard
import Sentry

/// Puts an `ErrorGuard` into Sentry's beforeSend. One line in the app's start, after the app's own settings:
///
/// ```swift
/// SentrySDK.start { options in /* the app's settings */; SentryGuard.install(options, guard: guardian) }
/// ```
///
/// The app's own callback (set before `install`) runs first; what it drops is never counted.
/// Android: lt-error-guard-sentry-android/SentryGuard.kt.
public enum SentryGuard {
    /// sentry-cocoa 9.x: when set, it replaces beforeSend (SentryClient calls only one of them).
    static let withHintKey = "beforeSendWithHint"
    typealias WithHint = @convention(block) (Event, AnyObject) -> Event?

    public static func install(_ options: Options, guard guardian: ErrorGuard) {
        let filter: @Sendable (Event) -> Event? = { e in guardian.decide(guardEvent(e)).keep ? e : nil }
        // Through the runtime, so this still builds against 8.x, which has no beforeSendWithHint. The hint is passed on untouched.
        if options.responds(to: NSSelectorFromString(withHintKey)), let previous = options.value(forKey: withHintKey) as AnyObject? {
            let call = unsafeBitCast(previous, to: WithHint.self)
            let wrapped: WithHint = { event, hint in call(event, hint).flatMap(filter) }
            options.setValue(wrapped, forKey: withHintKey)
            return
        }
        let previous = options.beforeSend
        options.beforeSend = { event in (previous.map { $0(event) } ?? event).flatMap(filter) }
    }

    /// What the rules see of `event`; Sentry has already filled in exceptions, threads and in-app frames.
    public static func guardEvent(_ event: Event) -> GuardEvent {
        let exceptions = event.exceptions ?? []
        var frames = exceptions.flatMap { $0.stacktrace?.frames ?? [] }
        // Only crash reports put the stack on the exception; capture(error:) / capture(exception:) put it on the current thread.
        if frames.isEmpty, let threads = event.threads {
            let thread = threads.first { $0.current?.boolValue == true && $0.stacktrace != nil }
                ?? threads.first { $0.crashed?.boolValue == true && $0.stacktrace != nil }
                ?? threads.first { $0.stacktrace != nil }
            frames = thread?.stacktrace?.frames ?? []
        }
        let types = exceptions.map { x in [x.module, x.type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".") }.filter { !$0.isEmpty }
        var messages = [event.message?.formatted, event.message?.message].compactMap { $0 } + exceptions.compactMap(\.value)
        messages = messages.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let isInApp = { (f: Frame) in f.inApp?.boolValue == true }
        let fingerprint = types.first.map { ([$0] + [codePath(frames, isInApp)].compactMap { $0 }).joined(separator: "|") }
            // The message template when the app captured a formatted message, else the text.
            ?? event.message?.message ?? event.message?.formatted ?? ""
        return GuardEvent(
            exceptionTypes: types,
            messages: messages,
            frames: frames.count,
            inAppFrames: frames.filter(isInApp).count,
            level: level(event.level),
            tags: event.tags ?? [:],
            crashed: exceptions.contains { $0.mechanism?.handled?.boolValue == false },
            fingerprint: fingerprint
        )
    }

    /// Which code path sent the event. With function names: the last (throwing) in-app frame, else the top frame.
    /// Without (the SDK symbolicates on the server, so a real event has only image + address): a hash of every frame's
    /// image offset. The top frames alone are not enough there: a statically linked Sentry puts its own frames on top,
    /// and in the app's image, so every call site would look the same. Offsets are stable for one build.
    static func codePath(_ frames: [Frame], _ isInApp: (Frame) -> Bool) -> String? {
        guard !frames.isEmpty else { return nil }
        if let f = frames.last(where: isInApp) ?? frames.last, let fn = symbol(f) { return "\(f.module ?? "").\(fn)" }
        return "stack:" + fnv1a(frames.map(offset).joined(separator: "\n"))
    }

    private static func symbol(_ f: Frame) -> String? {
        guard let fn = f.function, !fn.isEmpty, fn != "<redacted>" else { return nil }
        return fn
    }

    /// `image+0x<offset>`; the raw address when the image base is unknown.
    private static func offset(_ f: Frame) -> String {
        let image = (f.package as NSString?)?.lastPathComponent ?? ""
        let hex = { (s: String?) in s.flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } }
        if let i = hex(f.instructionAddress), let base = hex(f.imageAddress), i >= base { return "\(image)+0x\(String(i - base, radix: 16))" }
        return "\(image)@\(f.instructionAddress ?? "")"
    }

    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    static func level(_ l: SentryLevel) -> String {
        switch l {
        case .fatal: "fatal"
        case .warning: "warning"
        case .info: "info"
        case .debug: "debug"
        default: "error"
        }
    }
}
