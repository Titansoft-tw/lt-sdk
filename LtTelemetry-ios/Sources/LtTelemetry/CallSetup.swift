import Foundation

// Port of lt-telemetry-android CallSetup.kt. Keep the two in step.

/// Call-setup stages reported as `sdk_event` / `label = "call_setup"` (shared telemetry contract,
/// item 2). `rawValue` is the `reason` attribute; one record per stage per leg.
public enum SetupStage: String, CaseIterable, Sendable {
    case dial, pushReceived = "push_received", ringing, accept, tokenOk = "token_ok", joinStart = "join_start"
    case joined, joinFailed = "join_failed", peerJoined = "peer_joined", peerAudioStarted = "peer_audio_started"
    case firstAudio = "first_audio"
    // Phase 2 (push path): the push woke the app; the call was reported to CallKit.
    case appWoken = "app_woken", callkitReported = "callkit_reported"

    public var title: String {
        switch self {
        case .dial: "撥號"
        case .pushReceived: "收到推播"
        case .ringing: "響鈴"
        case .accept: "接聽"
        case .tokenOk: "取得憑證"
        case .joinStart: "開始加入"
        case .joined: "已加入"
        case .joinFailed: "加入失敗"
        case .peerJoined: "對方加入"
        case .peerAudioStarted: "對方音訊開始"
        case .firstAudio: "首次聽到聲音"
        case .appWoken: "喚醒完成"
        case .callkitReported: "CallKit 回報"
        }
    }
}

/// Names for Agora's integer codes, so `detail` reads "state=FAILED reason=JOIN_FAILED" rather than "5/4".
public enum AgoraCodes {
    public static func connectionState(_ state: Int) -> String {
        switch state {
        case 1: "DISCONNECTED"
        case 2: "CONNECTING"
        case 3: "CONNECTED"
        case 4: "RECONNECTING"
        case 5: "FAILED"
        default: "STATE_\(state)"
        }
    }
    private static let reasons = ["CONNECTING", "JOIN_SUCCESS", "INTERRUPTED", "BANNED_BY_SERVER", "JOIN_FAILED", "LEAVE_CHANNEL",
                                  "INVALID_APP_ID", "INVALID_CHANNEL_NAME", "INVALID_TOKEN", "TOKEN_EXPIRED", "REJECTED_BY_SERVER",
                                  "SETTING_PROXY_SERVER", "RENEW_TOKEN", "CLIENT_IP_ADDRESS_CHANGED", "KEEP_ALIVE_TIMEOUT",
                                  "REJOIN_SUCCESS", "LOST", "ECHO_TEST", "CLIENT_IP_ADDRESS_CHANGED_BY_USER", "SAME_UID_LOGIN",
                                  "TOO_MANY_BROADCASTERS", "LICENSE_VALIDATION_FAILURE", "CERTIFICATE_VERIFICATION_FAILURE",
                                  "STREAM_CHANNEL_NOT_AVAILABLE", "INCONSISTENT_APPID"]
    public static func connectionReason(_ reason: Int) -> String {
        reasons.indices.contains(reason) ? reasons[reason] : "REASON_\(reason)"
    }
    public static func connection(_ state: Int, _ reason: Int) -> String {
        "state=\(connectionState(state)) reason=\(connectionReason(reason))"
    }
    public static func remoteAudioState(_ state: Int) -> String {
        let names = ["STOPPED", "STARTING", "DECODING", "FROZEN", "FAILED"]
        return names.indices.contains(state) ? names[state] : "STATE_\(state)"
    }
    public static func remoteAudioReason(_ reason: Int) -> String {
        let names = ["INTERNAL", "NETWORK_CONGESTION", "NETWORK_RECOVERY", "LOCAL_MUTED", "LOCAL_UNMUTED",
                     "REMOTE_MUTED", "REMOTE_UNMUTED", "REMOTE_OFFLINE", "NO_PACKET_RECEIVE", "LOCAL_PLAY_FAILED"]
        return names.indices.contains(reason) ? names[reason] : "REASON_\(reason)"
    }
    /// LOCAL_AUDIO_STREAM_REASON_* → name, so `agora_local_audio` reasons read "interrupted" rather than "8".
    public static func localAudioReason(_ reason: Int) -> String {
        let names = ["ok", "failure", "device_no_permission", "device_busy", "capture_failure", "encode_failure",
                     "no_recording_device", "no_playout_device", "interrupted", "record_invalid_id", "playout_invalid_id"]
        return names.indices.contains(reason) ? names[reason] : "reason_\(reason)"
    }
    public static func localAudioState(_ state: Int) -> String {
        let names = ["stopped", "recording", "encoding", "failed"]
        return names.indices.contains(state) ? names[state] : "state_\(state)"
    }
    /// Why the other side left: 0 quit, 1 dropped, 2 become audience.
    public static func userOfflineReason(_ reason: Int) -> String {
        let names = ["quit", "dropped", "become_audience"]
        return names.indices.contains(reason) ? names[reason] : "reason_\(reason)"
    }
    /// permissionError type: 0 record audio, 1 camera, 2 screen capture.
    public static func permissionType(_ type: Int) -> String {
        let names = ["record_audio", "camera", "screen_capture"]
        return names.indices.contains(type) ? names[type] : "type_\(type)"
    }

    // app_error codes (contract decisions 7): stable, so they can be grouped and counted.
    /// didOccurError: the engine ends the call on it, so it is fatal.
    public static func onError(_ code: Int, detail: String) -> AppError { AppError(.rtc, "agora_error_\(abs(code))", detail: detail, fatal: true) }
    /// joinChannel (or a setup call before it) returned a negative code.
    public static func joinFailed(_ code: Int, detail: String) -> AppError { AppError(.rtc, "agora_join_failed_\(abs(code))", detail: detail, fatal: true) }
    public static func connectionFailed(_ reason: Int) -> AppError {
        AppError(.rtc, "agora_conn_failed_\(connectionReason(reason).lowercased())", detail: "state=FAILED reason=\(connectionReason(reason))", fatal: true)
    }
    public static func localAudioFailed(_ reason: Int) -> AppError { AppError(.audio, "agora_local_audio_failed_\(localAudioReason(reason))", detail: "local audio failed") }
    public static func encryptionError(_ type: Int) -> AppError { AppError(.rtc, "agora_encryption_\(type)", detail: "encryption error type \(type)") }
    public static func permissionError(_ type: Int) -> AppError {
        AppError(.permission, "agora_permission_\(permissionType(type))", detail: "permission error \(permissionType(type))")
    }

    /// `networkTypeChanged` → contract value (item 3): what the SDK believes the network is.
    public static func netType(_ type: Int) -> String {
        switch type {
        case 0: "none"
        case 1: "ethernet"
        case 2: "wifi"
        case 3: "2g"
        case 4: "3g"
        case 5: "4g"
        case 6: "5g"
        default: "unknown"
        }
    }
}
