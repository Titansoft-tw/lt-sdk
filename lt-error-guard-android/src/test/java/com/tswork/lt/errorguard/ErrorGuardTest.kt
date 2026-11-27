package com.tswork.lt.errorguard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** What the vectors cannot show: threads, re-entrant sinks, the matcher's corners. */
class ErrorGuardTest {
    private val net = """{"version": 1, "sessionBudget": {"maxEvents": 50}, "rules": [
        {"id": "net", "match": {"exceptionType": ["java.net.*"]}, "action": "dedupe", "domain": "api", "code": "http_network"}]}"""

    @Test fun concurrentEventsKeepTheBudgetAndCountsExact() {
        val guard = ErrorGuard(GuardRules.parse(net))
        val kept = AtomicInteger()
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        repeat(8) { t ->
            pool.execute {
                start.await()
                repeat(1000) { i ->
                    val e = if (i % 2 == 0) GuardEvent(exceptionTypes = listOf("java.net.UnknownHostException"), fingerprint = "f${i % 10}")
                    else GuardEvent(messages = listOf("thread $t event $i"))
                    if (guard.decide(e).keep) kept.incrementAndGet()
                }
            }
        }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(30, TimeUnit.SECONDS))
        assertEquals(50, kept.get())
        assertEquals(8000 - 50, guard.tallies().sumOf { it.count })
    }

    @Test fun aSinkMayCallBackIntoTheGuard() {
        lateinit var guard: ErrorGuard
        val seen = mutableListOf<Suppressed>()
        guard = ErrorGuard(GuardRules.parse(net), { first -> seen += first; guard.tallies(); guard.decide(GuardEvent(messages = listOf("from sink"))) })
        val e = GuardEvent(exceptionTypes = listOf("java.net.ConnectException"))
        assertTrue(guard.decide(e).keep)
        assertFalse(guard.decide(e).keep)
        assertEquals(listOf(Suppressed("net", "api", "http_network", 1)), seen)
    }

    @Test fun globCorners() {
        fun m(p: String, t: String) = Glob(p, ignoreCase = false).matches(t)
        assertTrue(m("*", ""))
        assertTrue(m("**a**", "a"))
        assertTrue(m("a*b*c", "aXbYbZc"))
        assertFalse(m("a*b*c", "aXbYbZ"))
        assertTrue(m("?", "x"))
        assertFalse(m("?", ""))
        assertTrue(m("[a]+", "[a]+"))
        assertFalse(m("a", "A"))
        assertTrue(Glob("*NOT_AVAILABLE*", ignoreCase = true).matches("service_not_available"))
    }

    @Test fun parseReportsEveryProblemAtOnce() {
        val e = runCatching { GuardRules.parse("""{"version": 2, "rules": [{"id": "A", "match": {}, "action": "x"}]}""") }.exceptionOrNull()
        val lines = e!!.message!!.lines()
        assertTrue(lines.toString(), lines.any { "version" in it } && lines.any { "id must" in it } && lines.any { "action" in it })
    }

    @Test fun notJsonIsRejected() {
        assertTrue(runCatching { GuardRules.parse("{") }.exceptionOrNull() is IllegalArgumentException)
        assertTrue(runCatching { GuardRules.parse("") }.exceptionOrNull() is IllegalArgumentException)
    }

    @Test fun integralNumbersAreIntegers() {
        assertEquals(3, GuardRules.parse("""{"version": 1.0, "sessionBudget": {"maxEvents": 3.0}, "rules": []}""").maxEvents)
    }

    @Test fun theDefaultSampleDrawIsInRange() {
        val guard = ErrorGuard(GuardRules.parse("""{"version": 1, "rules": [
            {"id": "half", "match": {}, "action": "sample", "rate": 0.5, "domain": "api", "code": "x"}]}"""))
        val kept = (1..2000).count { guard.decide(GuardEvent()).keep }
        assertTrue("kept $kept of 2000", kept in 800..1200)
    }
}
