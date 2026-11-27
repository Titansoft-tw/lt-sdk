package com.tswork.lt.errorguard

import java.util.Locale
import java.util.concurrent.ThreadLocalRandom

/*
 * Decides which handled error events reach the crash reporter (lt-error-guard-spec). SDK-free: the
 * Sentry adapter (lt-error-guard-sentry-android) turns a Sentry event into a [GuardEvent]. iOS mirrors
 * it in LtErrorGuard/ErrorGuard.swift; both run lt-error-guard-spec/vectors.
 */

/** One error event as the rules see it. */
data class GuardEvent(
    /** `module.type` of every exception in the chain (iOS NSError: the domain). */
    val exceptionTypes: List<String> = emptyList(),
    /** The message and every exception value. */
    val messages: List<String> = emptyList(),
    /** Stack frames in all exceptions, and how many of them are the app's own. */
    val frames: Int = 0,
    val inAppFrames: Int = 0,
    /** fatal / error / warning / info / debug. */
    val level: String = "error",
    val tags: Map<String, String> = emptyMap(),
    /** Unhandled: the process or the thread died. Crashes are always kept. */
    val crashed: Boolean = false,
    /** Groups events for dedupe; blank = the first exception type, else the first message. */
    val fingerprint: String = "",
)

/** [rule]: the rule that decided, `budget` for the session budget, null when nothing matched (or a crash). */
data class Decision(val keep: Boolean, val rule: String? = null)

/** Events a rule suppressed in this session, reported as app_error ([domain], [code], [count]). */
data class Suppressed(val rule: String, val domain: String, val code: String, val count: Int)

/** Called once per rule and session, at the first suppressed event (count 1), outside the guard's lock. */
fun interface GuardSink {
    fun suppressed(first: Suppressed)
}

/**
 * Thread-safe: crash reporters call beforeSend from any thread. A session runs from creation (or the last
 * [endSession]) to the next [endSession]; the app picks it (the process, or one call).
 */
class ErrorGuard @JvmOverloads constructor(
    rules: GuardRules = GuardRules.DEFAULT,
    private val sink: GuardSink = GuardSink {},
    /** A draw in [0, 1) for action sample. */
    private val random: () -> Double = { ThreadLocalRandom.current().nextDouble() },
) {
    private val lock = Any()
    /** Read and replaced only under [lock]. */
    private var rules = rules
    private val seen = HashSet<String>()
    private val tallies = LinkedHashMap<String, Suppressed>()
    private var kept = 0

    fun decide(event: GuardEvent): Decision {
        if (event.crashed || event.level == "fatal") return Decision(true)
        val lower = event.messages.map { it.lowercase(Locale.ROOT) }
        var first: Suppressed? = null
        val decision = synchronized(lock) {
            val rule = rules.rules.firstOrNull { it.matches(event, lower) }
            val keep = when (rule?.action) {
                null, Action.KEEP -> true
                Action.DROP -> false
                Action.SAMPLE -> random() < rule.rate
                Action.DEDUPE -> seen.add(rule.id + "\u0000" + key(event))
            }
            val max = rules.maxEvents
            when {
                !keep -> { first = suppress(rule!!.id, rule.domain, rule.code); Decision(false, rule.id) }
                max != null && kept >= max -> { first = suppress(BUDGET, BUDGET_DOMAIN, BUDGET_CODE); Decision(false, BUDGET) }
                else -> { kept++; Decision(true, rule?.id) }
            }
        }
        first?.let(sink::suppressed)
        return decision
    }

    /**
     * Replaces the rules (e.g. from [GuardRulesLoader]); the next event uses them. This session's dedupe marks,
     * budget and counts stay. Crashes stay protected whatever the rules say.
     */
    fun updateRules(rules: GuardRules) = synchronized(lock) { this.rules = rules }

    /** Every suppression count in this session, in first-seen order. */
    fun tallies(): List<Suppressed> = synchronized(lock) { tallies.values.toList() }

    /** The counts above 1 (the first was already sent through the sink), then a fresh session. */
    fun endSession(): List<Suppressed> = synchronized(lock) {
        val totals = tallies.values.filter { it.count > 1 }
        tallies.clear(); seen.clear(); kept = 0
        totals
    }

    /** Returns the first suppression for the sink, or null when this rule already reported one. */
    private fun suppress(rule: String, domain: String, code: String): Suppressed? {
        val key = "$rule\u0000$domain\u0000$code"
        val next = tallies[key]?.let { it.copy(count = it.count + 1) } ?: Suppressed(rule, domain, code, 1)
        tallies[key] = next
        return next.takeIf { it.count == 1 }
    }

    private fun key(e: GuardEvent) = e.fingerprint.ifBlank { e.exceptionTypes.firstOrNull() ?: e.messages.firstOrNull() ?: "" }

    companion object {
        const val BUDGET = "budget"
        const val BUDGET_DOMAIN = "telemetry"
        const val BUDGET_CODE = "error_budget_exceeded"
    }
}
