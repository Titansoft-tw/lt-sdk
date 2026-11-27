# lt-error-guard-sentry-android (#8)

Puts the error guard (#7) into Sentry's `beforeSend`. `io.sentry:sentry` is `compileOnly` (built against 8.0.0,
tested with 8.63.0): the app's own `sentry-android` provides it.

```kotlin
val guard = ErrorGuard(GuardRules.DEFAULT)
SentryAndroid.init(context) { options ->
    options.dsn = "..."                       // the app's settings, its own beforeSend included
    SentryGuard.install(options, guard)       // last: the app's beforeSend runs first
}
```

`SentryGuard.guardEvent(event)`: exception types are `module.type`; fingerprint = first exception type plus the last
in-app frame (`module.function`), or the top frame when none is in-app, or the message for message events; `crashed`
= Sentry's `isCrashed` (an unhandled mechanism). If the guard throws, the event is kept.

Known gap: a non-fatal ANR (Android 10 and lower, level error, `handled` unset) is not `crashed` yet, so the budget or
a rule can drop it.

**R8 / ProGuard builds**: Sentry marks frames in-app by class-name prefix (`inAppIncludes`, the app's package by
default) on the device, before deobfuscation. If the build renames packages, no app frame is in-app: `inApp` rules and
the default `third-party-only` see app errors as third-party. Events are still told apart by their top frame, so each
call site is kept once per session. Keep the package names (`-keeppackagenames com.example.**`) or add the obfuscated
prefixes to `inAppIncludes` when `inApp` matters.
