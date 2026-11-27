package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.AudioRoute
import com.tswork.lt.deviceinfo.DeviceState
import com.tswork.lt.deviceinfo.NetworkSnapshot
import com.tswork.lt.deviceinfo.StaticDevice
import java.util.Locale
import kotlin.math.roundToLong

/**
 * Live telemetry for lt-observability: OTLP/HTTP JSON log records posted to an OpenTelemetry
 * Collector (`POST /v1/logs`, see [LtTelemetry]). The record body is the message type and every value travels
 * as a string attribute; the platform's ClickHouse views cast them (see lt-observability
 * docs/ARCHITECTURE.md, "遙測契約"). Carries no credentials and no IP address.
 */
data class TelemetryRecord(val body: String, val atEpochMs: Long, val attributes: Map<String, String>,
                           /** OTLP severityText: INFO for everything except app_error ([Severity]). */
                           val severity: String = Severity.INFO)

/** Identifies one leg of one call. Both legs must send the same [callId] to be joined. */
data class TelemetryLeg(
    val callId: String,
    val channel: String,
    val user: String,
    val peer: String = "",
    val engine: String,
    val role: String? = null,
    /** Self-hosted LiveKit region the call went through; blank for other engines. */
    val region: String = "",
    val lab: LabTag? = null,
    /** The engine's SDK, e.g. "agora-4.7.0"; overrides the device-wide value. */
    val sdkVersion: String = "",
    /** Connectivity experiments in effect (proxy, transport, relay, ice_policy); empty with the defaults. */
    val extra: Map<String, String> = emptyMap(),
)

/** A Lab run's identity, carried on every record of the run. */
data class LabTag(val runId: String, val caseId: String, val role: String, val group: Int = 0, val envOk: Boolean = true)

/** What telemetry sends from one per-second engine sample. Null means unavailable, never a measured zero. */
data class AudioMetrics(
    val lossPct: Double? = null,
    val jitterMs: Double? = null,
    val rttMs: Double? = null,
    val receiveKbps: Double? = null,
    val sendKbps: Double? = null,
    val endToEndMs: Double? = null,
    val jitterBufferMs: Double? = null,
    val concealPct: Double? = null,
    val mos: Double? = null,
    val protocol: String? = null,
    val candidateType: String? = null,
    val relayProtocol: String? = null,
    val codec: String? = null,
    /** Uplink loss as the other side reports it back (RTCP receiver reports / Agora local stats). */
    val sendLossPct: Double? = null,
    /** Share of time the received audio was frozen (Agora only). */
    val freezePct: Double? = null,
    /**
     * Engine-specific measurements sent as they are (keys namespaced agora_ / rtc_, e.g. agora_mos_raw,
     * rtc_nack_count). Never addresses or names: these go off the device.
     */
    val extra: Map<String, String> = emptyMap(),
)

/**
 * What the device is on right now, read once a second. Blank means unknown. [audioDevice] must
 * already be passed through [com.tswork.lt.deviceinfo.deviceModel]: accessory names often carry the owner's name.
 */
data class TelemetryContext(
    val netType: String = "",      // wifi / 5g / 4g / 3g / 2g / cellular / ethernet / other / none
    val carrier: String = "",
    val country: String = "",
    val audioRoute: String = "",   // speaker / earpiece / wired / bluetooth
    val audioDevice: String = "",
    val btProfile: String = "",    // hfp / a2dp / le_audio
    val vpn: String = "",          // "1" while a VPN carries the traffic, "0" without one, blank if unknown
    /** Contract values only (wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown): what the OS says. */
    val netTypeOs: String = "",
    /** What the media SDK says (Agora onNetworkTypeChanged); blank when the engine reports none. */
    val netTypeSdk: String = "",
    /** Country the relay (via Cloudflare) sees this phone's traffic exit from: the VPN exit when one is on. */
    val exitCountry: String = "",
    /** Radio levels only, keys already final (wifi_rssi_dbm, cell_rsrp_dbm, ...); never SSIDs, cell ids or location. */
    val signal: Map<String, String> = emptyMap(),
    /** Battery, power save, thermal and microphone state; unknown fields stay null and are not sent. */
    val device: DeviceState = DeviceState(),
) {
    /** From lt-device-info's readers; [netTypeSdk] is what the media engine says (blank when it reports none). */
    constructor(net: NetworkSnapshot, route: AudioRoute, device: DeviceState, netTypeSdk: String = "") : this(
        netType = net.netType, carrier = net.carrier, country = net.country, audioRoute = route.route, audioDevice = route.device,
        btProfile = route.btProfile, vpn = net.vpn, netTypeOs = net.netTypeOs, netTypeSdk = netTypeSdk, exitCountry = net.exitCountry,
        signal = net.signal, device = device)

    val route get() = Triple(audioRoute, audioDevice, btProfile)
}

object Telemetry {
    const val QUALITY_SECOND = "quality_second"
    const val SDK_EVENT = "sdk_event"
    const val CALL_SETUP = "call_setup"
    const val APP_ERROR = "app_error"

    /** The platform stores leg ids as UInt32, so "001234" is sent as "1234"; non-numeric ids pass through. */
    internal fun uid(id: String) = id.toLongOrNull()?.takeIf { it >= 0 }?.toString() ?: id

    private fun identity(leg: TelemetryLeg) = buildMap {
        put("call_id", leg.callId)
        put("channel", leg.channel)
        put("leg_uid", uid(leg.user))
        if (leg.peer.isNotBlank()) put("peer_uid", uid(leg.peer))
        put("engine", leg.engine)
        leg.role?.let { put("role", it) }
        if (leg.region.isNotBlank()) put("server_region", leg.region)
        leg.lab?.let { put("test_run_id", it.runId); put("case_id", it.caseId); put("test_role", it.role); if (it.group > 0) put("test_group", it.group.toString()); if (!it.envOk) put("env_ok", "0") }
        if (leg.sdkVersion.isNotBlank()) put("sdk_version", leg.sdkVersion)
        putAll(leg.extra)
    }

    /**
     * One per-second sample. An unmeasured metric is left out rather than sent as zero. The
     * platform's integer columns reject decimals, so millisecond values are rounded here.
     */
    fun qualitySecond(leg: TelemetryLeg, m: AudioMetrics, atEpochMs: Long, context: TelemetryContext = TelemetryContext(),
                      appForeground: Boolean? = null) = TelemetryRecord(QUALITY_SECOND, atEpochMs, buildMap {
        putAll(identity(leg))
        for ((key, value) in listOf("net_type" to context.netType, "carrier" to context.carrier, "country" to context.country,
            "audio_route" to context.audioRoute, "audio_device" to context.audioDevice, "bt_profile" to context.btProfile, "vpn" to context.vpn,
            "net_type_os" to context.netTypeOs, "net_type_sdk" to context.netTypeSdk, "exit_country" to context.exitCountry) + context.signal.toList()) {
            if (value.isNotBlank()) put(key, value)
        }
        // Device state (error log / device state phase 1): unknown is left out, so 0 always means 0.
        appForeground?.let { put("app_fg", flag(it)) }
        context.device.powerSave?.let { put("power_save", flag(it)) }
        context.device.thermal?.let { put("thermal", it.toString()) }
        context.device.micSilenced?.let { put("mic_silenced", flag(it)) }
        context.device.batteryPct?.let { put("battery_pct", it.toString()) }
        fun decimal(key: String, value: Double?) {
            if (value != null && value.isFinite()) put(key, String.format(Locale.US, "%.2f", value))
        }
        fun whole(key: String, value: Double?) {
            if (value != null && value.isFinite()) put(key, value.coerceAtLeast(0.0).roundToLong().toString())
        }
        decimal("tx_audio_kbps", m.sendKbps)
        decimal("rx_audio_kbps", m.receiveKbps)
        decimal("tx_loss_pct", m.sendLossPct)
        decimal("rx_loss_pct", m.lossPct)
        decimal("freeze_rate_pct", m.freezePct)
        whole("rtt_ms", m.rttMs)
        whole("jitter_ms", m.jitterMs)
        whole("e2e_delay_ms", m.endToEndMs)
        whole("jitter_buffer_ms", m.jitterBufferMs)
        m.protocol?.let { put("transport", it.lowercase(Locale.US)) }
        m.candidateType?.let { put("relay", if (it == "relay") "1" else "0") }
        decimal("conceal_pct", m.concealPct)
        decimal("mos", m.mos)
        m.candidateType?.let { put("candidate_type", it) }
        m.relayProtocol?.let { put("relay_protocol", it.lowercase(Locale.US)) }
        m.codec?.let { put("codec", it) }
        putAll(m.extra)
    })

    fun sdkEvent(leg: TelemetryLeg, label: String, event: String, reason: String, atEpochMs: Long, detail: String = "",
                 extra: Map<String, String> = emptyMap()) =
        TelemetryRecord(SDK_EVENT, atEpochMs, identity(leg) + mapOf("label" to label, "event" to event, "reason" to reason) +
            (if (detail.isNotBlank()) mapOf("detail" to detail.take(240)) else emptyMap()) + extra)

    /** Contract item 2: one per stage per leg; [stage] is one of [SetupStage] codes. */
    fun callSetup(leg: TelemetryLeg, stage: SetupStage, detail: String, atEpochMs: Long, extra: Map<String, String> = emptyMap()) =
        sdkEvent(leg, CALL_SETUP, "call setup: ${stage.code}", stage.code, atEpochMs, detail, extra)

    /** A session that ended before joining without an error (user cancel, standby rebuild): not a join_failed. */
    fun cancelledBeforeJoin(leg: TelemetryLeg, detail: String, atEpochMs: Long) =
        sdkEvent(leg, "session", "session cancelled before join", "cancelled", atEpochMs, detail)

    /** Every engine connection-state change, e.g. Agora "state=CONNECTING reason=JOIN_SUCCESS" or WebRTC ICE. */
    fun connectionState(leg: TelemetryLeg, state: String, detail: String, atEpochMs: Long) =
        sdkEvent(leg, "connection_state", "connection state $state", state, atEpochMs, detail)

    /** iOS AVAudioSession notifications: route_changed (with the system's reason), interrupted, interruption_ended. */
    fun audioSession(leg: TelemetryLeg, reason: String, detail: String, atEpochMs: Long) =
        sdkEvent(leg, "audio_session", "audio session $reason", reason, atEpochMs, detail)

    private fun flag(value: Boolean) = if (value) "1" else "0"

    /**
     * `app_error` (severity from [AppError.severity]). Unlike sdk_event it carries the network
     * context itself; platform, versions, device model and brand come from [logsJson]. Without a
     * call ([leg] null or without an id yet) there is no call_id.
     */
    fun appError(error: AppError, stage: String, count: Int, atEpochMs: Long, leg: TelemetryLeg? = null,
                 context: TelemetryContext = TelemetryContext()) = TelemetryRecord(APP_ERROR, atEpochMs, buildMap {
        leg?.let { putAll(identity(it)); if (it.callId.isBlank()) remove("call_id") }
        put("error_domain", error.domain.code)
        put("error_code", error.code)
        put("stage", stage)
        put("fatal", flag(error.fatal))
        put("count", count.toString())
        scrub(error.detail).takeIf { it.isNotBlank() }?.let { put("detail", it) }
        put("source", "app")
        error.sentryEventId.takeIf { SENTRY_EVENT_ID.matches(it) }?.let { put("sentry_event_id", it) }
        for ((key, value) in listOf("net_type" to context.netType, "carrier" to context.carrier, "country" to context.country)) {
            if (value.isNotBlank()) put(key, value)
        }
    }, error.severity)

    private val EMAIL = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private val IPV4 = Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    // Full 8-group or compressed (::) IPv6 with at least one hex group, optionally with a %zone. Like the Collector's
    // rule it must start and end at a boundary, so C++ names (std::bad_alloc, Foo::Bar) and times (12:30:45) are kept.
    private val IPV6 = Regex("(?<![0-9A-Za-z_:.])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?|::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})(?::(?:\\d{1,3}\\.){3}\\d{1,3})?(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z_:]|\\.\\d)")
    private val SENTRY_EVENT_ID = Regex("[0-9a-f]{32}")
    /** Client-side scrubbing of free text (the Collector does it again): IPv4, IPv6 and email are masked, then capped at 240. */
    fun scrub(text: String): String = mask(text).take(240)
    /** [scrub] without the length cap (Sentry messages and breadcrumbs). */
    fun mask(text: String): String =
        // IPv6 first: it takes an IPv4-mapped address (::ffff:10.0.0.1) whole.
        text.replace(EMAIL, "<email>").replace(IPV6, "<ip>").replace(IPV4, "<ip>")

    /** Plain events without a call (app_start): no identity, the device fields come from [logsJson]. */
    fun appEvent(label: String, event: String, reason: String, atEpochMs: Long, detail: String = "", extra: Map<String, String> = emptyMap()) =
        TelemetryRecord(SDK_EVENT, atEpochMs, mapOf("label" to label, "event" to event, "reason" to reason) +
            (if (detail.isNotBlank()) mapOf("detail" to scrub(detail)) else emptyMap()) + extra)

    /** Once per process start: the denominator for errors per session. */
    fun appStart(atEpochMs: Long) = appEvent("app_start", "app start", "app_start", atEpochMs)

    /** At launch, for a call the process did not survive; identity comes from the marker written during the call. */
    fun abnormalExit(marker: CallMarker, exitReason: String, atEpochMs: Long) = TelemetryRecord(SDK_EVENT, atEpochMs, buildMap {
        put("call_id", marker.callId)
        if (marker.channel.isNotBlank()) put("channel", marker.channel)
        if (marker.user.isNotBlank()) put("leg_uid", uid(marker.user))
        if (marker.engine.isNotBlank()) put("engine", marker.engine)
        if (marker.sdkVersion.isNotBlank()) put("sdk_version", marker.sdkVersion)
        put("label", "abnormal_exit"); put("event", "abnormal exit"); put("reason", "abnormal_exit")
        put("detail", "exit_reason=$exitReason")
    })

    /** `label=env`: the phone's state when a call starts. Only fields this platform can tell are sent. */
    fun envSnapshot(leg: TelemetryLeg, state: DeviceState, brand: String, atEpochMs: Long) = sdkEvent(leg, "env", "environment snapshot", "snapshot", atEpochMs,
        extra = buildMap {
            state.batteryPct?.let { put("battery_pct", it.toString()) }
            state.charging?.let { put("charging", flag(it)) }
            state.powerSave?.let { put("power_save", flag(it)) }
            state.thermal?.let { put("thermal", it.toString()) }
            state.doze?.let { put("doze", flag(it)) }
            state.batteryOptExempt?.let { put("battery_opt_exempt", flag(it)) }
            state.bgRestricted?.let { put("bg_restricted", flag(it)) }
            state.standbyBucket?.let { put("standby_bucket", it) }
            state.micPerm?.let { put("mic_perm", it) }
            state.notifPerm?.let { put("notif_perm", it) }
            state.fullscreenIntentPerm?.let { put("fullscreen_intent_perm", it) }
            if (brand.isNotBlank()) put("device_brand", brand)
        })

    /** Stamps the call's final id and the test scenario when a batch leaves the device. */
    fun stamp(record: TelemetryRecord, callId: String, testScenario: String) = record.copy(attributes = record.attributes +
        ("call_id" to callId) + if (testScenario.isNotBlank()) mapOf("test_scenario" to testScenario) else emptyMap())

    fun netChanged(leg: TelemetryLeg, from: String, to: String, atEpochMs: Long) =
        sdkEvent(leg, "network", "network changed $from -> $to", "net_changed", atEpochMs)

    fun reconnecting(leg: TelemetryLeg, active: Boolean, netType: String, atEpochMs: Long) = sdkEvent(leg, "network",
        if (active) "reconnecting" else "reconnected${if (netType.isNotBlank()) " on $netType" else ""}",
        if (active) "reconnecting" else "reconnected", atEpochMs)

    fun routeChanged(leg: TelemetryLeg, from: TelemetryContext, to: TelemetryContext, atEpochMs: Long): TelemetryRecord {
        val detail = listOf(to.audioDevice, to.btProfile).filter { it.isNotBlank() }.joinToString(", ")
        return sdkEvent(leg, "audio_route",
            "audio route changed ${from.audioRoute.ifBlank { "unknown" }} -> ${to.audioRoute.ifBlank { "unknown" }}" +
                if (detail.isNotBlank()) " ($detail)" else "", "route_changed", atEpochMs)
    }

    /**
     * OTLP/HTTP JSON for `/v1/logs`. Device fields go on every record because the views read log attributes;
     * sdk_version comes from the record (the engine that produced it) and is left out when there is none.
     */
    fun logsJson(records: List<TelemetryRecord>, device: StaticDevice, serviceName: String, observedEpochMs: Long? = null): String {
        // observedTimeUnixNano = when the batch left the device; timeUnixNano stays when the record was made, so a record
        // delivered late (after an outage or a crash) shows how late it was.
        val observed = observedEpochMs?.let { """"observedTimeUnixNano":"${it}000000",""" }.orEmpty()
        val common = mapOf("platform" to device.platform, "os_version" to device.osVersion, "app_version" to device.appVersion) +
            listOfNotNull(device.model.takeIf { it.isNotBlank() }?.let { "device_model" to it },
                device.brand.takeIf { it.isNotBlank() }?.let { "device_brand" to it })
        val logs = records.joinToString(",") { record ->
            val attributes = (common + record.attributes).entries.filterNot { isSecretAttribute(it.key) }.joinToString(",") { (key, value) ->
                """{"key":${quote(key)},"value":{"stringValue":${quote(value)}}}"""
            }
            """{"timeUnixNano":"${record.atEpochMs}000000",$observed"severityText":${quote(record.severity)},"body":{"stringValue":${quote(record.body)}},"attributes":[$attributes]}"""
        }
        return """{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":${quote(serviceName)}}}]},"scopeLogs":[{"logRecords":[$logs]}]}]}"""
    }

    /**
     * Last line of defence (docs/e2ee.md): an attribute whose name looks like key material, a
     * credential or the E2EE safety code is dropped at encoding time, whoever added it.
     */
    private val SECRET_ATTRIBUTE = Regex(Contract.SECRET_PATTERN)
    fun isSecretAttribute(name: String) = SECRET_ATTRIBUTE.containsMatchIn(name)

    private fun quote(text: String) = buildString(text.length + 2) {
        append('"')
        for (c in text) when {
            c == '"' -> append("\\\"")
            c == '\\' -> append("\\\\")
            c < ' ' || c == '\u007f' -> append(String.format(Locale.US, "\\u%04x", c.code))
            else -> append(c)
        }
        append('"')
    }
}
