package com.tswork.lt.errorguard.sentry

import com.tswork.lt.errorguard.ErrorGuard
import com.tswork.lt.errorguard.GuardEvent
import com.tswork.lt.errorguard.GuardRules
import com.tswork.lt.errorguard.Suppressed
import io.sentry.Hint
import io.sentry.SentryEvent
import io.sentry.SentryLevel
import io.sentry.SentryOptions
import io.sentry.protocol.Mechanism
import io.sentry.protocol.Message
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/** The adapter on the SDK's real option and event classes (no SDK started, no network). */
class SentryGuardTest {
    private fun frame(module: String, function: String, inApp: Boolean?) = SentryStackFrame().apply { this.module = module; this.function = function; isInApp = inApp }

    private fun exception(module: String?, type: String, value: String?, handled: Boolean?, vararg frames: SentryStackFrame) = SentryException().apply {
        this.module = module; this.type = type; this.value = value
        mechanism = Mechanism().apply { this.type = "generic"; isHandled = handled }
        stacktrace = SentryStackTrace(frames.toList())
    }

    private fun event(vararg exceptions: SentryException, level: SentryLevel = SentryLevel.ERROR) = SentryEvent().apply {
        this.exceptions = exceptions.toList(); this.level = level
    }

    @Test fun aHandledNetworkErrorBecomesAGuardEvent() {
        val e = event(
            exception("java.net", "UnknownHostException", "Unable to resolve host \"fcm.googleapis.com\"", true,
                frame("okhttp3.internal", "connect", false), frame("com.app.push", "register", true), frame("java.net", "lookup", false)),
            level = SentryLevel.WARNING,
        ).apply { setTag("gms", "missing") }
        assertEquals(GuardEvent(
            exceptionTypes = listOf("java.net.UnknownHostException"),
            messages = listOf("Unable to resolve host \"fcm.googleapis.com\""),
            frames = 3, inAppFrames = 1, level = "warning", tags = mapOf("gms" to "missing"),
            crashed = false, fingerprint = "java.net.UnknownHostException|com.app.push.register",
        ), SentryGuard.guardEvent(e))
    }

    @Test fun anUnhandledExceptionIsACrash() {
        assertEquals(true, SentryGuard.guardEvent(event(exception("java.lang", "NullPointerException", null, false))).crashed)
    }

    @Test fun aMessageEventGroupsByItsTemplate() {
        val e = SentryEvent().apply { message = Message().apply { message = "timeout after %d s"; formatted = "timeout after 3 s" } }
        val g = SentryGuard.guardEvent(e)
        assertEquals(listOf("timeout after 3 s", "timeout after %d s"), g.messages)
        assertEquals("timeout after %d s", g.fingerprint)
        assertEquals(emptyList<String>(), g.exceptionTypes)
        assertEquals("error", g.level) // no level set
    }

    @Test fun installKeepsTheFirstAndDropsRepeatsWithTheDefaultRules() {
        val sunk = mutableListOf<Suppressed>()
        val options = SentryOptions()
        SentryGuard.install(options, ErrorGuard(GuardRules.DEFAULT, { sunk += it }))
        val net = { event(exception("java.net", "SocketTimeoutException", "timeout", true, frame("com.app", "call", true))) }
        val first = net()
        assertSame(first, options.beforeSend!!.execute(first, Hint()))
        assertNull(options.beforeSend!!.execute(net(), Hint()))
        val crash = event(exception("java.net", "SocketTimeoutException", "timeout", false))
        assertSame(crash, options.beforeSend!!.execute(crash, Hint()))
        assertEquals(listOf(Suppressed("net-io", "api", "http_network", 1)), sunk)
    }

    @Test fun theAppsOwnBeforeSendRunsFirstAndWhatItDropsIsNotCounted() {
        val order = mutableListOf<String>()
        val options = SentryOptions().apply {
            beforeSend = SentryOptions.BeforeSendCallback { e, _ -> order += "app"; if (e.getTag("drop") == "1") null else e.apply { setTag("seen", "1") } }
        }
        val guard = ErrorGuard(GuardRules.parse("""{"version": 1, "rules": [
            {"id": "seen", "match": {"tags": {"seen": ["1"]}}, "action": "dedupe", "domain": "api", "code": "x"}]}"""))
        SentryGuard.install(options, guard)
        assertNull(options.beforeSend!!.execute(SentryEvent().apply { setTag("drop", "1") }, Hint()))
        val kept = options.beforeSend!!.execute(SentryEvent(), Hint())
        assertEquals("1", kept?.getTag("seen")) // the guard saw the app's tag
        assertEquals(listOf("app", "app"), order)
        assertEquals(emptyList<Suppressed>(), guard.tallies())
    }

    @Test fun aThrowingGuardKeepsTheEvent() {
        val options = SentryOptions()
        SentryGuard.install(options, ErrorGuard(GuardRules.parse("""{"version": 1, "rules": [
            {"id": "s", "match": {}, "action": "sample", "rate": 0.5, "domain": "api", "code": "x"}]}""")) { error("broken draw") })
        val e = SentryEvent()
        assertSame(e, options.beforeSend!!.execute(e, Hint()))
    }
}
