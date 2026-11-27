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
in-app frame (`module.function`), or the message template for message events; `crashed` = Sentry's `isCrashed`
(unhandled mechanism, which includes ANRs). If the guard throws, the event is kept.
