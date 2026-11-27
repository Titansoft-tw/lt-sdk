# LtErrorGuardSentry (#10)

Puts `LtErrorGuard` (#9) into sentry-cocoa's `beforeSend` (package range 8.0.0..<10.0.0; tested with 8.58.4 and 9.36.0).

```swift
SentrySDK.start { options in
    options.dsn = "..."                                   // the app's settings, its own beforeSend included
    SentryGuard.install(options, guard: guardian)          // last: the app's beforeSend runs first
}
```

Call `install` after setting the app's own callback. In sentry-cocoa 9.x an app's `beforeSendWithHint` replaces
`beforeSend`; `install` then wraps `beforeSendWithHint` instead (through the runtime, so the package still builds
against 8.x).

NSError events have the error domain as exception type (`NSURLErrorDomain`); `crashed` = any exception mechanism with
`handled == false` (crash reports). Only crash reports put the stack on the exception; for `capture(error:)` /
`capture(exception:)` the frames come from the current thread. Real events carry no function names (Sentry symbolicates
on the server), so the fingerprint is the exception type plus a hash of every frame's image offset: one call site gives
one fingerprint per build, different call paths differ. With function names (e.g. hand-built events) it is the last
in-app frame, as on Android.

Known gap: a non-fatal app hang (level error, `handled` unset) is not `crashed` yet, so the budget or a rule can drop it.
