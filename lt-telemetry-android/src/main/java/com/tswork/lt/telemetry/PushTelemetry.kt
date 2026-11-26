package com.tswork.lt.telemetry

/*
 * Phase 2 of the error log (docs/error-device-telemetry.md「第 2 期」): the incoming-call push path,
 * the foreground service and crash reporting. Pure code; iOS mirrors it in LtTelemetry/PushTelemetry.swift.
 * AppLaunch and AppLaunchTracker live in lt-device-info.
 */

/** Push and incoming-call errors (domain push / audio), with the contract's severities. */
object PushErrors {
    /** RemoteMessage.PRIORITY_HIGH = 1, PRIORITY_NORMAL = 2; anything else (UNKNOWN 0) is not sent. */
    fun fcmPriority(value: Int): String? = when (value) { 1 -> "high"; 2 -> "normal"; else -> null }

    /** The system delivered an FCM message at another priority than it was sent with (WARN). Null when unknown or equal. */
    fun downgraded(priority: String?, original: String?): AppError? =
        if (priority == null || original == null || priority == original) null
        else AppError(ErrorDomain.PUSH, "fcm_priority_downgraded", "priority=$priority original=$original", severity = Severity.WARN)

    /** `POST /v1/devices` answered [status]: null on success and on 501 (push not configured on the relay: expected). */
    fun register(status: Int): AppError? =
        if (status in 200..299 || status == 501) null else AppError(ErrorDomain.PUSH, ApiErrors.status(status), "POST /v1/devices")

    /** No push token to register (FCM getToken failed, empty VoIP token). */
    fun tokenUnavailable(detail: String) = AppError(ErrorDomain.PUSH, "push_token_register_failed", detail)

    /** iOS: CallKit refused reportNewIncomingCall. */
    fun callKitReportFailed(detail: String) = AppError(ErrorDomain.PUSH, "callkit_report_failed", detail)

    /** iOS: the call was answered but CallKit never activated the audio session (one-way silence). */
    fun callKitAudioNotActivated(afterMs: Long) =
        AppError(ErrorDomain.AUDIO, "callkit_audio_not_activated", "no didActivate ${afterMs / 1000} s after answer")
}

/** `sdk_event label=fgs`: the call's microphone foreground service. */
object Fgs {
    const val LABEL = "fgs"
    const val STARTED = "started"
    const val START_DENIED = "start_denied"
    const val STOPPED = "stopped"

    /**
     * Android 12+ refuses a foreground service started from the background
     * (ForegroundServiceStartNotAllowedException); Android 14 refuses a microphone one without the
     * while-in-use permission (SecurityException). Either way the microphone is silenced in the background.
     */
    fun denied(e: Throwable) = AppError(ErrorDomain.PERMISSION, "fgs_start_denied", "${e.javaClass.simpleName}: ${e.message.orEmpty()}")
}
