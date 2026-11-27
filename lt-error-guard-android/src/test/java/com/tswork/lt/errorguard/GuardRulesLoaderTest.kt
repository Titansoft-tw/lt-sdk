package com.tswork.lt.errorguard

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

/** lt-error-guard-spec/vectors/remote (signed with a fixture-only key), which LtErrorGuardTests run too. */
class GuardRulesLoaderTest {
    @get:Rule val tmp = TemporaryFolder()

    private val remote = File("../lt-error-guard-spec/vectors/remote")
    private val publicKey = File(remote, "test.pub.pem").readText()
    private val url = "https://rules.example/guard.json"
    private val net = GuardEvent(exceptionTypes = listOf("java.net.UnknownHostException"))

    /** Serves [name] (and its .sig) from the fixtures at [url]; null = the server is down. */
    private class Server(var name: String?, private val dir: File) {
        var calls = 0
        fun fetch(u: String): ByteArray {
            calls++
            val n = name ?: throw IOException("connection refused")
            return File(dir, if (u.endsWith(".sig")) "$n.sig" else n).readBytes()
        }
    }

    private fun loader(guard: ErrorGuard, server: Server, cache: File? = File(tmp.root, "rules.json"), applied: MutableList<Int> = mutableListOf()) =
        GuardRulesLoader(guard, url, publicKey, cache, fetch = server::fetch, onApplied = { applied += it })

    @Test fun theSharedCases() {
        val cases = JSONObject(File(remote, "cases.json").readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val result = loader(ErrorGuard(GuardRules.DEFAULT), Server(c.getString("file"), remote), cache = null).refresh()
            when (c.getString("expect")) {
                "applied" -> assertEquals(c.getString("file"), RulesUpdate.Applied(c.getInt("version")), result)
                else -> assertTrue("${c.getString("file")}: $result", result is RulesUpdate.Rejected && result.reason.startsWith(c.getString("reason")))
            }
        }
    }

    @Test fun appliedRulesChangeTheGuardsDecisions() {
        val guard = ErrorGuard(GuardRules.parse("""{"version": 1, "rules": []}"""))
        assertTrue(guard.decide(net).keep)
        val applied = mutableListOf<Int>()
        assertEquals(RulesUpdate.Applied(2), loader(guard, Server("v2.json", remote), applied = applied).refresh())
        assertEquals(Decision(false, "net"), guard.decide(net))
        assertEquals(listOf(2), applied)
    }

    @Test fun onlyNewerVersionsApply() {
        val guard = ErrorGuard(GuardRules.DEFAULT)
        val server = Server("v3.json", remote)
        val l = loader(guard, server)
        assertEquals(RulesUpdate.Applied(3), l.refresh())
        server.name = "v2.json"
        assertEquals(RulesUpdate.Unchanged(3), l.refresh())
        server.name = "v3.json"
        assertEquals(RulesUpdate.Unchanged(3), l.refresh())
        assertTrue(guard.decide(net).keep) // still v3 (no rules), not v2's drop
    }

    @Test fun refusedOrFailedDownloadsKeepTheCurrentRules() {
        val guard = ErrorGuard(GuardRules.DEFAULT)
        val server = Server("v2.json", remote)
        val l = loader(guard, server)
        assertEquals(RulesUpdate.Applied(2), l.refresh())
        for (bad in listOf("tampered.json", "wrong-key.json", "invalid-rules.json")) {
            server.name = bad
            assertTrue(bad, l.refresh() is RulesUpdate.Rejected)
        }
        server.name = null
        assertTrue(l.refresh() is RulesUpdate.Failed)
        assertEquals(2, l.version)
        assertEquals(Decision(false, "net"), guard.decide(net))
    }

    @Test fun theCacheSurvivesARestartAndBlocksRollback() {
        val cache = File(tmp.root, "rules.json")
        assertEquals(RulesUpdate.Applied(2), loader(ErrorGuard(GuardRules.DEFAULT), Server("v2.json", remote), cache).refresh())
        assertTrue(File(tmp.root, "rules.json.sig").exists())
        // Next launch, offline: the cached v2 applies before anything is sent.
        val guard = ErrorGuard(GuardRules.parse("""{"version": 1, "rules": []}"""))
        val applied = mutableListOf<Int>()
        val offline = Server(null, remote)
        val l = loader(guard, offline, cache, applied)
        assertTrue(l.applyCached())
        assertEquals(2, l.version)
        assertEquals(Decision(false, "net"), guard.decide(net))
        assertEquals(listOf(2), applied)
        assertEquals(0, offline.calls)
    }

    @Test fun aTamperedCacheIsIgnored() {
        val cache = File(tmp.root, "rules.json")
        loader(ErrorGuard(GuardRules.DEFAULT), Server("v2.json", remote), cache).refresh()
        cache.writeText(File(remote, "tampered.json").readText())
        val l = loader(ErrorGuard(GuardRules.DEFAULT), Server(null, remote), cache)
        assertFalse(l.applyCached())
        assertEquals(0, l.version)
        assertFalse(loader(ErrorGuard(GuardRules.DEFAULT), Server(null, remote), File(tmp.root, "missing.json")).applyCached())
    }

    @Test fun envelopeProblems() {
        fun reason(json: String) = runCatching { GuardRulesLoader.parseEnvelope(json.toByteArray()) }.exceptionOrNull()?.message.orEmpty()
        assertTrue(reason("[]").startsWith("envelope"))
        assertTrue(reason("""{"rulesVersion": 0, "rules": {"version": 1, "rules": []}}""").contains("rulesVersion"))
        assertTrue(reason("""{"rulesVersion": 1.5, "rules": {"version": 1, "rules": []}}""").contains("rulesVersion"))
        assertTrue(reason("""{"rulesVersion": 1, "rules": {"version": 1, "rules": []}, "extra": 1}""").contains("extra"))
        assertTrue(reason("""{"rulesVersion": 1}""").contains("rules must be an object"))
        assertTrue(reason("""{"rulesVersion": 1, "rules": {"version": 2, "rules": []}}""").startsWith("rules.version"))
        assertEquals(7, GuardRulesLoader.parseEnvelope("""{"rulesVersion": 7, "rules": {"version": 1, "rules": []}}""".toByteArray()).first)
    }

    @Test fun anInvalidPublicKeyFailsAtConstruction() {
        assertTrue(runCatching { GuardRulesLoader(ErrorGuard(), url, "not a key", null) }.exceptionOrNull() is IllegalArgumentException)
        // Base64 without PEM armour works too.
        val b64 = publicKey.lines().filterNot { it.startsWith("-----") }.joinToString("")
        GuardRulesLoader(ErrorGuard(), url, b64, null)
    }

    @Test fun periodicRefreshRunsOnItsOwnThread() {
        val guard = ErrorGuard(GuardRules.DEFAULT)
        val server = Server("v2.json", remote)
        val l = loader(guard, server)
        l.startPeriodic(intervalMs = 60_000).use {
            val until = System.currentTimeMillis() + 5_000
            while (l.version == 0 && System.currentTimeMillis() < until) Thread.sleep(20)
        }
        assertEquals(2, l.version)
    }
}
