import Foundation
import LtErrorGuard
import Sentry

/// Puts an `ErrorGuard` into Sentry's beforeSend. One line in the app's start:
///
/// ```swift
/// SentrySDK.start { options in /* the app's settings */; SentryGuard.install(options, guard: guardian) }
/// ```
///
/// The app's own beforeSend (set before `install`) runs first; what it drops is never counted.
/// Android: lt-error-guard-sentry-android/SentryGuard.kt.
public enum SentryGuard {
    public static func install(_ options: Options, guard guardian: ErrorGuard) {
        let previous = options.beforeSend
        options.beforeSend = { event in
            guard let e = previous.map({ $0(event) }) ?? event else { return nil }
            return guardian.decide(guardEvent(e)).keep ? e : nil
        }
    }

    /// What the rules see of `event`; Sentry has already filled in exceptions and in-app frames.
    public static func guardEvent(_ event: Event) -> GuardEvent {
        let exceptions = event.exceptions ?? []
        let frames = exceptions.flatMap { $0.stacktrace?.frames ?? [] }
        let types = exceptions.map { x in [x.module, x.type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".") }.filter { !$0.isEmpty }
        var messages = [event.message?.formatted, event.message?.message].compactMap { $0 } + exceptions.compactMap(\.value)
        messages = messages.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let isInApp = { (f: Frame) in f.inApp?.boolValue == true }
        // The frame that threw is the last one; its function groups the events a code path sends.
        let top = frames.last(where: isInApp).map { "\($0.module ?? "").\($0.function ?? "")" }
        let fingerprint = types.first.map { ([$0] + [top].compactMap { $0 }).joined(separator: "|") }
            // The message template, so "timeout after 3 s" and "after 5 s" are one event.
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
