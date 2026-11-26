package com.tswork.lt.telemetry

/**
 * Call-setup stages reported as `sdk_event` / `label = "call_setup"` (shared telemetry contract,
 * item 2). [code] is the `reason` attribute; one record per stage per leg.
 */
enum class SetupStage(val code: String, val title: String) {
    DIAL("dial", "撥號"), PUSH_RECEIVED("push_received", "收到推播"), RINGING("ringing", "響鈴"),
    ACCEPT("accept", "接聽"), TOKEN_OK("token_ok", "取得憑證"), JOIN_START("join_start", "開始加入"),
    JOINED("joined", "已加入"), JOIN_FAILED("join_failed", "加入失敗"), PEER_JOINED("peer_joined", "對方加入"),
    PEER_AUDIO_STARTED("peer_audio_started", "對方音訊開始"), FIRST_AUDIO("first_audio", "首次聽到聲音"),
    // Phase 2 (push path): the push woke the app; iOS reported the call to CallKit.
    APP_WOKEN("app_woken", "喚醒完成"), CALLKIT_REPORTED("callkit_reported", "CallKit 回報"),
}

/** Names for Agora's integer codes, so `detail` reads "state=FAILED reason=JOIN_FAILED" rather than "5/4". */
object AgoraCodes {
    fun connectionState(state: Int) = when (state) {
        1 -> "DISCONNECTED"; 2 -> "CONNECTING"; 3 -> "CONNECTED"; 4 -> "RECONNECTING"; 5 -> "FAILED"; else -> "STATE_$state"
    }
    fun connectionReason(reason: Int) = when (reason) {
        0 -> "CONNECTING"; 1 -> "JOIN_SUCCESS"; 2 -> "INTERRUPTED"; 3 -> "BANNED_BY_SERVER"; 4 -> "JOIN_FAILED"
        5 -> "LEAVE_CHANNEL"; 6 -> "INVALID_APP_ID"; 7 -> "INVALID_CHANNEL_NAME"; 8 -> "INVALID_TOKEN"; 9 -> "TOKEN_EXPIRED"
        10 -> "REJECTED_BY_SERVER"; 11 -> "SETTING_PROXY_SERVER"; 12 -> "RENEW_TOKEN"; 13 -> "CLIENT_IP_ADDRESS_CHANGED"
        14 -> "KEEP_ALIVE_TIMEOUT"; 15 -> "REJOIN_SUCCESS"; 16 -> "LOST"; 17 -> "ECHO_TEST"
        18 -> "CLIENT_IP_ADDRESS_CHANGED_BY_USER"; 19 -> "SAME_UID_LOGIN"; 20 -> "TOO_MANY_BROADCASTERS"
        21 -> "LICENSE_VALIDATION_FAILURE"; 22 -> "CERTIFICATE_VERIFICATION_FAILURE"; 23 -> "STREAM_CHANNEL_NOT_AVAILABLE"
        24 -> "INCONSISTENT_APPID"; else -> "REASON_$reason"
    }
    fun connection(state: Int, reason: Int) = "state=${connectionState(state)} reason=${connectionReason(reason)}"
    fun remoteAudioState(state: Int) = when (state) {
        0 -> "STOPPED"; 1 -> "STARTING"; 2 -> "DECODING"; 3 -> "FROZEN"; 4 -> "FAILED"; else -> "STATE_$state"
    }
    fun remoteAudioReason(reason: Int) = when (reason) {
        0 -> "INTERNAL"; 1 -> "NETWORK_CONGESTION"; 2 -> "NETWORK_RECOVERY"; 3 -> "LOCAL_MUTED"; 4 -> "LOCAL_UNMUTED"
        5 -> "REMOTE_MUTED"; 6 -> "REMOTE_UNMUTED"; 7 -> "REMOTE_OFFLINE"; 8 -> "NO_PACKET_RECEIVE"; 9 -> "LOCAL_PLAY_FAILED"
        else -> "REASON_$reason"
    }
    /** LOCAL_AUDIO_STREAM_REASON_* → name, so `agora_local_audio` reasons read "interrupted" rather than "8". */
    fun localAudioReason(reason: Int) = when (reason) {
        0 -> "ok"; 1 -> "failure"; 2 -> "device_no_permission"; 3 -> "device_busy"; 4 -> "capture_failure"; 5 -> "encode_failure"
        6 -> "no_recording_device"; 7 -> "no_playout_device"; 8 -> "interrupted"; 9 -> "record_invalid_id"; 10 -> "playout_invalid_id"
        else -> "reason_$reason"
    }
    fun localAudioState(state: Int) = when (state) { 0 -> "stopped"; 1 -> "recording"; 2 -> "encoding"; 3 -> "failed"; else -> "state_$state" }
    /** USER_OFFLINE_*: why the other side left. */
    fun userOfflineReason(reason: Int) = when (reason) { 0 -> "quit"; 1 -> "dropped"; 2 -> "become_audience"; else -> "reason_$reason" }
    /** onPermissionError's type: 0 RECORD_AUDIO, 1 CAMERA, 2 SCREEN_CAPTURE. */
    fun permissionType(type: Int) = when (type) { 0 -> "record_audio"; 1 -> "camera"; 2 -> "screen_capture"; else -> "type_$type" }

    // app_error codes (contract decisions 7): stable, so they can be grouped and counted.
    /** onError: the engine ends the call on it, so it is fatal. */
    fun onError(err: Int, detail: String) = AppError(ErrorDomain.RTC, "agora_error_${kotlin.math.abs(err)}", detail, fatal = true)
    /** joinChannel (or a setup call before it) returned a negative code. */
    fun joinFailed(code: Int, detail: String) = AppError(ErrorDomain.RTC, "agora_join_failed_${kotlin.math.abs(code)}", detail, fatal = true)
    fun connectionFailed(reason: Int) = AppError(ErrorDomain.RTC, "agora_conn_failed_${connectionReason(reason).lowercase()}",
        "state=FAILED reason=${connectionReason(reason)}", fatal = true)
    fun localAudioFailed(reason: Int) = AppError(ErrorDomain.AUDIO, "agora_local_audio_failed_${localAudioReason(reason)}", "local audio failed")
    fun encryptionError(type: Int) = AppError(ErrorDomain.RTC, "agora_encryption_$type", "encryption error type $type")
    fun permissionError(type: Int) = AppError(ErrorDomain.PERMISSION, "agora_permission_${permissionType(type)}", "permission error ${permissionType(type)}")

    /** `onNetworkTypeChanged` → contract value (item 3): what the SDK believes the network is. */
    fun netType(type: Int) = when (type) {
        0 -> "none"; 1 -> "ethernet"; 2 -> "wifi"; 3 -> "2g"; 4 -> "3g"; 5 -> "4g"; 6 -> "5g"; else -> "unknown"
    }
}
