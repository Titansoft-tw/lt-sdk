package com.tswork.lt.errorguard

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.util.Locale

/*
 * The rules file (lt-error-guard-spec/rules.schema.json). parse rejects what validate.js rejects
 * (vectors/invalid.json), so a file checked on a laptop behaves the same on the phone.
 */

internal enum class Action(val code: String) { KEEP("keep"), DROP("drop"), SAMPLE("sample"), DEDUPE("dedupe") }

/** `*` = any run of characters, `?` = exactly one; everything else is literal. */
internal class Glob(pattern: String, private val ignoreCase: Boolean) {
    private val p = if (ignoreCase) pattern.lowercase(Locale.ROOT) else pattern

    /** [text] is already lower case when [ignoreCase]. */
    fun matches(text: String): Boolean {
        var t = 0; var g = 0; var star = -1; var mark = 0
        while (t < text.length) {
            if (g < p.length && (p[g] == '?' || p[g] == text[t])) { t++; g++ }
            else if (g < p.length && p[g] == '*') { star = g++; mark = t }
            else if (star >= 0) { g = star + 1; t = ++mark }
            else return false
        }
        while (g < p.length && p[g] == '*') g++
        return g == p.length
    }
}

internal class GuardRule(
    val id: String,
    val action: Action,
    val rate: Double,
    val domain: String,
    val code: String,
    private val exceptionType: List<Glob>?,
    private val message: List<Glob>?,
    private val inApp: Boolean?,
    private val level: Set<String>?,
    private val tags: Map<String, List<Glob>>?,
) {
    /** [lowerMessages] = the event's messages in lower case (message globs ignore case). */
    fun matches(e: GuardEvent, lowerMessages: List<String>): Boolean {
        if (exceptionType != null && exceptionType.none { g -> e.exceptionTypes.any(g::matches) }) return false
        if (message != null && message.none { g -> lowerMessages.any(g::matches) }) return false
        if (inApp == true && e.inAppFrames <= 0) return false
        if (inApp == false && !(e.frames > 0 && e.inAppFrames <= 0)) return false
        if (level != null && e.level !in level) return false
        if (tags != null && !tags.all { (k, globs) -> e.tags[k]?.let { v -> globs.any { it.matches(v) } } == true }) return false
        return true
    }
}

class GuardRules private constructor(internal val rules: List<GuardRule>, val maxEvents: Int?) {
    companion object {
        /** The rules in lt-error-guard-spec/default-rules.json. */
        @JvmStatic val DEFAULT: GuardRules by lazy { parse(DefaultRules.JSON) }

        /** @throws IllegalArgumentException listing every problem when [json] is not a valid rules file. */
        @JvmStatic fun parse(json: String): GuardRules = Parser().run(json)

        private val ID = Regex("[a-z0-9_-]+")
        private val CODE = Regex("[a-z0-9_]+")
        private val LEVELS = setOf("error", "warning", "info", "debug")
    }

    private class Parser {
        val problems = mutableListOf<String>()

        fun run(json: String): GuardRules {
            val root = runCatching { JSONTokener(json).nextValue() }.getOrElse { throw IllegalArgumentException("rules: not JSON (${it.message})") }
            val parsed = (root as? JSONObject)?.let(::rules)
            if (root !is JSONObject) problems += "rules: must be an object"
            require(problems.isEmpty() && parsed != null) { problems.joinToString("\n") }
            return parsed
        }

        fun rules(o: JSONObject): GuardRules? {
            unknown("rules", o, "version", "sessionBudget", "rules")
            if (integer(o.opt("version")) != 1) problems += "version: must be 1"
            var max: Int? = null
            if (o.has("sessionBudget")) {
                val b = o.opt("sessionBudget") as? JSONObject
                if (b == null) problems += "sessionBudget: must be an object"
                else {
                    unknown("sessionBudget", b, "maxEvents")
                    max = integer(b.opt("maxEvents"))?.takeIf { it >= 1 }
                    if (max == null) problems += "sessionBudget.maxEvents: must be an integer of at least 1"
                }
            }
            val list = o.opt("rules") as? JSONArray ?: run { problems += "rules: must be a list"; return null }
            val ids = HashSet<String>()
            val out = (0 until list.length()).mapNotNull { i -> rule(i, list.opt(i), ids) }
            return GuardRules(out, max)
        }

        fun rule(i: Int, v: Any?, ids: MutableSet<String>): GuardRule? {
            val r = v as? JSONObject
            val id = r?.opt("id") as? String
            val where = "rules[$i]" + (id?.let { " ($it)" } ?: "")
            if (r == null) { problems += "$where: must be an object"; return null }
            val before = problems.size
            unknown(where, r, "id", "match", "action", "rate", "domain", "code")
            when {
                id == null || !ID.matches(id) -> problems += "$where: id must match $ID"
                id == "budget" -> problems += "$where: id budget is reserved for the session budget"
                !ids.add(id) -> problems += "$where: duplicate id"
            }
            val action = Action.entries.firstOrNull { it.code == r.opt("action") }
            if (action == null) problems += "$where: action must be one of ${Action.entries.joinToString { it.code }}"
            var rate = 0.0
            if (action == Action.SAMPLE) {
                rate = (r.opt("rate") as? Number)?.toDouble()?.takeIf { it in 0.0..1.0 } ?: run { problems += "$where: rate must be a number from 0 to 1"; 0.0 }
            } else if (r.has("rate")) problems += "$where: rate is only for action sample"
            var domain = ""; var code = ""
            if (action == Action.KEEP) {
                for (k in listOf("domain", "code")) if (r.has(k)) problems += "$where: a keep rule has no $k (nothing is suppressed)"
            } else if (action != null) {
                domain = r.opt("domain") as? String ?: ""
                code = r.opt("code") as? String ?: ""
                if (!CODE.matches(domain)) problems += "$where: domain must match $CODE"
                if (!CODE.matches(code)) problems += "$where: code must match $CODE"
            }
            val m = r.opt("match") as? JSONObject ?: run { problems += "$where: match must be an object"; return null }
            unknown("$where.match", m, "exceptionType", "message", "inApp", "level", "tags")
            val exceptionType = if (m.has("exceptionType")) globs("$where.match.exceptionType", m.opt("exceptionType"), false) else null
            val message = if (m.has("message")) globs("$where.match.message", m.opt("message"), true) else null
            val inApp = if (m.has("inApp")) m.opt("inApp") as? Boolean ?: run { problems += "$where.match.inApp: must be true or false"; null } else null
            var level: Set<String>? = null
            if (m.has("level")) {
                val l = (m.opt("level") as? JSONArray)?.let { a -> (0 until a.length()).map { a.opt(it) } }
                if (l.isNullOrEmpty() || !l.all { it is String && it in LEVELS }) {
                    problems += "$where.match.level: must be a non-empty list of ${LEVELS.joinToString()} (crashes are always kept)"
                } else level = l.map { it as String }.toSet()
            }
            var tags: Map<String, List<Glob>>? = null
            if (m.has("tags")) {
                val t = m.opt("tags") as? JSONObject
                if (t == null || t.length() == 0) problems += "$where.match.tags: must be a non-empty object"
                else tags = t.keys().asSequence().toList().associateWith { k -> globs("$where.match.tags.$k", t.opt(k), false) ?: emptyList() }
            }
            if (problems.size > before) return null
            return GuardRule(id!!, action!!, rate, domain, code, exceptionType, message, inApp, level, tags)
        }

        fun globs(where: String, v: Any?, ignoreCase: Boolean): List<Glob>? {
            val a = v as? JSONArray
            if (a == null || a.length() == 0) { problems += "$where: must be a non-empty list"; return null }
            val items = (0 until a.length()).map { a.opt(it) }
            if (!items.all { it is String && it.isNotEmpty() }) { problems += "$where: every glob must be a non-empty string"; return null }
            return items.map { Glob(it as String, ignoreCase) }
        }

        fun unknown(where: String, o: JSONObject, vararg allowed: String) {
            for (k in o.keys()) if (k !in allowed) problems += "$where: unknown key $k"
        }

        /** A whole number (1 and 1.0 alike, as in JavaScript), else null. */
        fun integer(v: Any?): Int? = (v as? Number)?.toDouble()?.takeIf { it % 1.0 == 0.0 && it in -1e9..1e9 }?.toInt()
    }
}
