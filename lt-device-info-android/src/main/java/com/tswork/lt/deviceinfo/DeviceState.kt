package com.tswork.lt.deviceinfo

/**
 * What the phone is doing, read once a second ([AndroidDeviceInfo.deviceState]) and, in full, once per call
 * ([AndroidDeviceInfo.deviceSnapshot]). Null = this platform or API level cannot tell; it is then not sent (never as 0).
 */
data class DeviceState(
    val batteryPct: Int? = null,
    val charging: Boolean? = null,
    val powerSave: Boolean? = null,
    /** 0–3, see [Thermal]. */
    val thermal: Int? = null,
    val doze: Boolean? = null,
    val batteryOptExempt: Boolean? = null,
    val bgRestricted: Boolean? = null,
    /** active / working_set / frequent / rare / restricted / unknown. */
    val standbyBucket: String? = null,
    /** granted / denied / undetermined. */
    val micPerm: String? = null,
    val notifPerm: String? = null,
    val fullscreenIntentPerm: String? = null,
    /** The system silenced this app's microphone (Android isClientSilenced, iOS audio session interruption). */
    val micSilenced: Boolean? = null,
    /** A cellular call holds the audio (Android MODE_IN_CALL). */
    val phoneCall: Boolean? = null,
)

/** Contract thermal levels: 0 nominal, 1 fair (light), 2 serious (severe), 3 critical or worse. */
object Thermal {
    /** PowerManager.THERMAL_STATUS_*: NONE 0, LIGHT 1, MODERATE 2, SEVERE 3, CRITICAL 4, EMERGENCY 5, SHUTDOWN 6. */
    fun android(status: Int): Int? = when (status) { 0 -> 0; 1, 2 -> 1; 3 -> 2; in 4..6 -> 3; else -> null }
    fun name(level: Int) = when (level) { 0 -> "nominal"; 1 -> "fair"; 2 -> "serious"; else -> "critical" }
}

/** ApplicationExitInfo.REASON_* → `exit_reason` (API 30+); iOS has none and always says "unknown". */
object ExitReasons {
    fun android(reason: Int) = when (reason) {
        0 -> "unknown"; 1 -> "exit_self"; 2 -> "signaled"; 3 -> "low_memory"; 4 -> "crash"; 5 -> "crash_native"; 6 -> "anr"
        7 -> "initialization_failure"; 8 -> "permission_change"; 9 -> "excessive_resource_usage"; 10 -> "user_requested"
        11 -> "user_stopped"; 12 -> "dependency_died"; 13 -> "other"; 14 -> "freezer"; 15 -> "package_state_change"; 16 -> "package_updated"
        else -> "reason_$reason"
    }
}
