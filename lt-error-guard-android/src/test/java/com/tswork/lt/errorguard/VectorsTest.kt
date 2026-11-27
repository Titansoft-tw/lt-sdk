package com.tswork.lt.errorguard

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** lt-error-guard-spec/vectors, which LtErrorGuardTests run too. */
class VectorsTest {
    private val spec = File("../lt-error-guard-spec")
    private fun read(name: String) = JSONObject(File(spec, name).readText())

    @Test fun decisions() {
        val cases = read("vectors/decisions.json").getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val rules = if (c.opt("rules") == "default") GuardRules.DEFAULT else GuardRules.parse(c.getJSONObject("rules").toString())
            var draw = 0.5
            val sunk = mutableListOf<Suppressed>()
            val guard = ErrorGuard(rules, { sunk += it }) { draw }
            val steps = c.getJSONArray("steps")
            for (s in 0 until steps.length()) {
                val step = steps.getJSONObject(s)
                if (step.has("endSession")) {
                    assertEquals("$name step $s", suppressed(step.getJSONArray("endSession")), guard.endSession())
                    continue
                }
                draw = step.optDouble("random", 0.5)
                val expect = step.getJSONObject("expect")
                val want = Decision(expect.getBoolean("keep"), expect.opt("rule").takeIf { it != JSONObject.NULL } as String?)
                assertEquals("$name step $s", want, guard.decide(event(step.getJSONObject("event"))))
            }
            if (c.has("tallies")) assertEquals("$name tallies", suppressed(c.getJSONArray("tallies")), guard.tallies())
            if (c.has("sink")) assertEquals("$name sink", suppressed(c.getJSONArray("sink")), sunk)
        }
    }

    @Test fun invalidRulesAreRejected() {
        val cases = read("vectors/invalid.json").getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val e = assertThrows(c.getString("name"), IllegalArgumentException::class.java) { GuardRules.parse(c.get("rules").toString()) }
            // Same wording as validate.js, so a field engineer sees one message on every platform.
            if (!e.message.orEmpty().contains(c.getString("error"))) fail("${c.getString("name")}: ${e.message}")
        }
    }

    @Test fun theGeneratedDefaultsAreTheSpecFile() {
        assertEquals(File(spec, "default-rules.json").readText().trimEnd(), DefaultRules.JSON.trim())
        assertEquals(30, GuardRules.DEFAULT.maxEvents)
    }

    private fun event(o: JSONObject) = GuardEvent(
        exceptionTypes = strings(o.optJSONArray("exceptionTypes")),
        messages = strings(o.optJSONArray("messages")),
        frames = o.optInt("frames"), inAppFrames = o.optInt("inAppFrames"),
        level = o.optString("level", "error"),
        tags = o.optJSONObject("tags")?.let { t -> t.keys().asSequence().associateWith { t.getString(it) } }.orEmpty(),
        crashed = o.optBoolean("crashed"),
        fingerprint = o.optString("fingerprint"),
    )

    private fun strings(a: JSONArray?) = a?.let { (0 until it.length()).map(it::getString) }.orEmpty()

    private fun suppressed(a: JSONArray) = (0 until a.length()).map { a.getJSONObject(it) }
        .map { Suppressed(it.getString("rule"), it.getString("domain"), it.getString("code"), it.getInt("count")) }
}
