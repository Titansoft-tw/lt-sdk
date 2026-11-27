# LtErrorGuardSentry (#10)

Puts `LtErrorGuard` (#9) into sentry-cocoa's `beforeSend` (package range 8.0.0..<10.0.0; tested with 8.58.4 and 9.36.0).

```swift
SentrySDK.start { options in
    options.dsn = "..."                                   // the app's settings, its own beforeSend included
    SentryGuard.install(options, guard: guardian)          // last: the app's beforeSend runs first
}
```

NSError events have the error domain as exception type (`NSURLErrorDomain`); `crashed` = any exception mechanism with
`handled == false` (crash reports). Fingerprint and messages follow the Android adapter.
