package com.tswork.lt.errorguard.sentry

import com.tswork.lt.errorguard.ErrorGuard
import com.tswork.lt.errorguard.GuardEvent
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import java.util.Locale

/**
 * Puts an [ErrorGuard] into Sentry's beforeSend. One line in the app's init:
 *
 * ```kotlin
 * SentryAndroid.init(context) { options -> /* the app's settings */; SentryGuard.install(options, guard) }
 * ```
 *
 * The app's own beforeSend (set before [install]) runs first; what it drops is never counted. If the guard
 * throws, the event is kept: a filter bug must not lose crashes.
 */
object SentryGuard {
    @JvmStatic fun install(options: SentryOptions, guard: ErrorGuard) {
        val previous = options.beforeSend
        options.beforeSend = SentryOptions.BeforeSendCallback { event, hint ->
            val e = if (previous == null) event else previous.execute(event, hint) ?: return@BeforeSendCallback null
            if (runCatching { guard.decide(guardEvent(e)).keep }.getOrDefault(true)) e else null
        }
    }

    /** What the rules see of [event]; Sentry's event processors have already filled in exceptions and in-app frames. */
    @JvmStatic fun guardEvent(event: SentryEvent): GuardEvent {
        val exceptions = event.exceptions.orEmpty()
        val frames = exceptions.flatMap { it.stacktrace?.frames.orEmpty() }
        val types = exceptions.map { x -> listOfNotNull(x.module?.takeIf { it.isNotBlank() }, x.type).joinToString(".") }.filter { it.isNotBlank() }
        val message = event.message
        val messages = listOfNotNull(message?.formatted, message?.message) + exceptions.mapNotNull { it.value }
        // The frame that threw is the last one; its function groups the events a code path sends.
        val top = frames.lastOrNull { it.isInApp == true }?.let { "${it.module.orEmpty()}.${it.function.orEmpty()}" }
        return GuardEvent(
            exceptionTypes = types,
            messages = messages.filter { it.isNotBlank() }.distinct(),
            frames = frames.size,
            inAppFrames = frames.count { it.isInApp == true },
            level = event.level?.name?.lowercase(Locale.ROOT) ?: "error",
            tags = event.tags.orEmpty(),
            crashed = event.isCrashed,
            fingerprint = when {
                types.isNotEmpty() -> listOfNotNull(types.first(), top).joinToString("|")
                // The message template, so "timeout after 3 s" and "after 5 s" are one event.
                else -> message?.message ?: message?.formatted.orEmpty()
            },
        )
    }
}
