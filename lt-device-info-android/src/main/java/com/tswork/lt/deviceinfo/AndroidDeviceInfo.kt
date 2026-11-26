package com.tswork.lt.deviceinfo

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.telephony.CellSignalStrengthLte
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Reads the device, network, audio route and power state. Only reads: sends nothing and needs no telemetry.
 * Every reader is cheap enough to call once a second and never throws; unknown values are blank or null.
 *
 * @param exitCountryLookup asked once per network (type + VPN) where the traffic exits, on a background thread
 *   (lt-call-demo: the relay's `GET /v1/whoami`); null = `exit_country` stays blank.
 */
class AndroidDeviceInfo(
    context: Context,
    private val exitCountryLookup: (() -> String?)? = null,
) {
    private val context = context.applicationContext
    private val background by lazy { Executors.newSingleThreadExecutor { Thread(it, "lt-device-info").apply { isDaemon = true } } }

    /** Platform, versions, model and brand; does not change while the process runs. */
    val staticDevice: StaticDevice by lazy {
        val appVersion = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()
        StaticDevice("android", Build.VERSION.RELEASE.orEmpty(), appVersion,
            model = "${Build.MANUFACTURER} ${Build.MODEL}".take(48), brand = Build.MANUFACTURER.orEmpty().take(32))
    }

    /** Milliseconds since this process started (`wake_ms` of a push that started it); null when unknown. */
    fun processUptimeMs(): Long? = (SystemClock.elapsedRealtime() - android.os.Process.getStartElapsedRealtime()).takeIf { it >= 0 }

    /** Why the previous process ended, if it ended after [sinceEpochMs] ([ExitReasons]); "unknown" when the OS does not say. */
    fun exitReason(sinceEpochMs: Long): String {
        if (Build.VERSION.SDK_INT < 30) return "unknown"
        val activity = context.getSystemService(ActivityManager::class.java) ?: return "unknown"
        return runCatching {
            activity.getHistoricalProcessExitReasons(context.packageName, 0, 5).firstOrNull { it.timestamp >= sinceEpochMs }?.let { ExitReasons.android(it.reason) }
        }.getOrNull() ?: "unknown"
    }

    /** A process woken by a push (no Activity) is not in the foreground; IMPORTANCE_FOREGROUND means a visible Activity. */
    fun isForeground(): Boolean? = runCatching {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }.getOrNull()

    // ---- Device state (quality_second device fields, label=env / device_power / mic) ----
    private val audio by lazy { context.getSystemService(AudioManager::class.java) }
    @Volatile private var micSilenced: Boolean? = null
    private var recordingWatched = false
    /** API 29+: the system silences an app's recording when another app (e.g. a phone call) takes the microphone. */
    private fun watchRecording() {
        if (recordingWatched || Build.VERSION.SDK_INT < 29) return
        recordingWatched = true
        fun silenced(configs: List<AudioRecordingConfiguration>?) = configs?.takeIf { it.isNotEmpty() }?.any { it.isClientSilenced }
        runCatching {
            micSilenced = silenced(audio.activeRecordingConfigurations)
            audio.registerAudioRecordingCallback(object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) { micSilenced = silenced(configs) }
            }, Handler(Looper.getMainLooper()))
        }
    }

    /** The once-a-second state: battery, power save, thermal, doze, microphone silenced, cellular call. */
    fun deviceState(): DeviceState = deviceState(full = false)

    /** The full state for the call's `label=env` snapshot (once per call): adds permissions and background limits. */
    fun deviceSnapshot(): DeviceState = deviceState(full = true)

    private fun deviceState(full: Boolean): DeviceState = runCatching {
        watchRecording()
        val battery = context.getSystemService(BatteryManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
        val pct = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 }
        val base = DeviceState(
            batteryPct = pct, charging = battery?.isCharging, powerSave = power?.isPowerSaveMode,
            thermal = if (Build.VERSION.SDK_INT >= 29) power?.currentThermalStatus?.let(Thermal::android) else null,
            doze = power?.isDeviceIdleMode, micSilenced = micSilenced,
            phoneCall = audio?.mode?.let { it == AudioManager.MODE_IN_CALL },
        )
        if (!full) return@runCatching base
        fun permission(name: String) = if (ContextCompat.checkSelfPermission(context, name) == PackageManager.PERMISSION_GRANTED) "granted" else "denied"
        val activity = context.getSystemService(ActivityManager::class.java)
        val notifications = context.getSystemService(NotificationManager::class.java)
        base.copy(
            batteryOptExempt = power?.isIgnoringBatteryOptimizations(context.packageName),
            bgRestricted = if (Build.VERSION.SDK_INT >= 28) activity?.isBackgroundRestricted else null,
            standbyBucket = if (Build.VERSION.SDK_INT >= 28) context.getSystemService(UsageStatsManager::class.java)?.appStandbyBucket?.let {
                when (it) { 5, 10 -> "active"; 20 -> "working_set"; 30 -> "frequent"; 40 -> "rare"; 45 -> "restricted"; else -> "unknown" }
            } else null,
            micPerm = permission(Manifest.permission.RECORD_AUDIO),
            notifPerm = if (Build.VERSION.SDK_INT >= 33) permission(Manifest.permission.POST_NOTIFICATIONS)
                else if (notifications?.areNotificationsEnabled() == false) "denied" else "granted",
            fullscreenIntentPerm = if (Build.VERSION.SDK_INT >= 34) (if (notifications?.canUseFullScreenIntent() == true) "granted" else "denied") else "granted",
        )
    }.getOrDefault(DeviceState())

    // ---- Network ----
    /** Network type, carrier, country, VPN, exit country and radio levels. Also read without telemetry (Lab check). */
    fun network(): NetworkSnapshot = runCatching {
        val telephony = context.getSystemService(TelephonyManager::class.java)
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val vpn = connectivity.getNetworkCapabilities(connectivity.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val net = netType(telephony)
        val vpnFlag = when (vpn) { true -> "1"; false -> "0"; null -> "" }
        refreshExitCountry("$net|$vpnFlag")
        NetworkSnapshot(netType = net, netTypeOs = osNetType(net, telephony), carrier = telephony?.networkOperatorName.orEmpty().take(32),
            country = telephony?.networkCountryIso.orEmpty().uppercase(Locale.US), vpn = vpnFlag,
            exitCountry = exitCountry, signal = signal(connectivity, telephony))
    }.getOrDefault(NetworkSnapshot())

    @Volatile private var exitCountry = ""
    @Volatile private var exitKey: String? = null
    /** Asks once per network (type + VPN) where the traffic exits; [network] is read every second. */
    private fun refreshExitCountry(key: String) {
        if (key == exitKey) return
        exitKey = key; exitCountry = ""
        val lookup = exitCountryLookup ?: return
        background.execute { runCatching(lookup).getOrNull()?.let { if (exitKey == key) exitCountry = it } }
    }

    /** Wi-Fi and cellular radio levels. Unavailable values (Integer.MAX_VALUE, -127 dBm) are left out. */
    private fun signal(connectivity: ConnectivityManager, telephony: TelephonyManager?): Map<String, String> = buildMap {
        @Suppress("DEPRECATION")
        val wifiCaps = connectivity.allNetworks.mapNotNull { connectivity.getNetworkCapabilities(it) }
            .firstOrNull { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }
        // Android 12+ can hand back a redacted WifiInfo through NetworkCapabilities; the WifiManager copy still has the levels.
        @Suppress("DEPRECATION")
        val wifi = if (wifiCaps == null) null
            else (if (Build.VERSION.SDK_INT >= 29) (wifiCaps.transportInfo as? WifiInfo)?.takeIf { it.rssi in -126..0 } else null)
                ?: context.getSystemService(WifiManager::class.java)?.connectionInfo
        if (wifi != null) {
            if (wifi.rssi in -126..0) put("wifi_rssi_dbm", wifi.rssi.toString())
            if (wifi.linkSpeed > 0) put("wifi_link_mbps", wifi.linkSpeed.toString())
            when (wifi.frequency) { in 2400..2500 -> "2.4"; in 4900..5900 -> "5"; in 5925..7125 -> "6"; else -> null }?.let { put("wifi_band_ghz", it) }
        }
        // getCellSignalStrengths and CellSignalStrengthNr are API 29.
        if (telephony != null && Build.VERSION.SDK_INT >= 29) {
            telephony.signalStrength?.let { strength ->
                put("cell_level", strength.level.toString())
                for (cell in strength.cellSignalStrengths) when (cell) {
                    is CellSignalStrengthNr -> {
                        if (cell.ssRsrp != Int.MAX_VALUE) put("cell_rsrp_dbm", cell.ssRsrp.toString())
                        if (cell.ssSinr != Int.MAX_VALUE) put("cell_sinr_db", cell.ssSinr.toString())
                    }
                    is CellSignalStrengthLte -> {
                        if (cell.rsrp != Int.MAX_VALUE && !containsKey("cell_rsrp_dbm")) put("cell_rsrp_dbm", cell.rsrp.toString())
                        if (cell.rssnr != Int.MAX_VALUE && !containsKey("cell_sinr_db")) put("cell_sinr_db", cell.rssnr.toString())
                    }
                }
            }
        }
        connectivity.getNetworkCapabilities(connectivity.activeNetwork)?.let {
            put("net_expensive", if (it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) "0" else "1")
        }
        // Data Saver, with this app exempted (WHITELISTED) counted as off: it is not restricted then.
        put("low_data_mode", if (connectivity.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED) "1" else "0")
        telephony?.let { put("roaming", if (it.isNetworkRoaming) "1" else "0") }
    }

    private fun netType(telephony: TelephonyManager?): String {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        var caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return "none"
        // With a VPN up the active network is the VPN itself; report the Wi-Fi or cellular link underneath.
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            @Suppress("DEPRECATION")
            val links = connectivity.allNetworks.mapNotNull { connectivity.getNetworkCapabilities(it) }
                .filter { !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
            // With mobile data kept on in the background, Wi-Fi (when present) is the link the VPN rides on.
            caps = links.firstOrNull { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) }
                ?: links.firstOrNull() ?: caps
        }
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> cellularGeneration(telephony)
            else -> "other"
        }
    }

    /**
     * `net_type_os`. On cellular, Android 12+ gets the generation the status bar shows from TelephonyDisplayInfo
     * without any permission, which is also the only way to see 5G NSA (data network type says LTE, the override
     * says NR). Older versions fall back to dataNetworkType when READ_PHONE_STATE happens to be granted.
     */
    private fun osNetType(net: String, telephony: TelephonyManager?): String {
        if (net == "cellular" || net in setOf("2g", "3g", "4g", "5g")) {
            displayInfo(telephony)?.let { (type, override) -> return OsNetType.cellular(type, override) }
        }
        return OsNetType.normalize(net)
    }
    @Volatile private var display: Pair<Int, Int>? = null
    private var displayListening = false
    private fun displayInfo(telephony: TelephonyManager?): Pair<Int, Int>? {
        if (Build.VERSION.SDK_INT < 31 || telephony == null) return null
        if (!displayListening) {
            displayListening = true
            runCatching {
                telephony.registerTelephonyCallback(context.mainExecutor, object : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
                    override fun onDisplayInfoChanged(info: TelephonyDisplayInfo) { display = info.networkType to info.overrideNetworkType }
                })
            }
        }
        return display
    }
    /** The generation needs READ_PHONE_STATE; without it this is just "cellular". */
    private fun cellularGeneration(telephony: TelephonyManager?): String {
        if (telephony == null || ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return "cellular"
        return when (telephony.dataNetworkType) {
            TelephonyManager.NETWORK_TYPE_NR -> "5g"
            TelephonyManager.NETWORK_TYPE_LTE, TelephonyManager.NETWORK_TYPE_IWLAN -> "4g"
            TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_HSPA, TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B, TelephonyManager.NETWORK_TYPE_EHRPD,
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3g"
            @Suppress("DEPRECATION")
            TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT, TelephonyManager.NETWORK_TYPE_GSM -> "2g"
            else -> "cellular"
        }
    }

    // ---- Audio route ----
    /** Route, accessory model and Bluetooth profile of the device call audio is on. */
    fun audioRoute(): AudioRoute = runCatching {
        if (Build.VERSION.SDK_INT >= 31) {
            val device = audio.communicationDevice ?: return@runCatching AudioRoute()
            fun bluetooth(profile: String) = AudioRoute("bluetooth", deviceModel(device.productName?.toString()), profile)
            return@runCatching when (device.type) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> AudioRoute("speaker")
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> AudioRoute("earpiece")
                AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> AudioRoute("wired")
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> bluetooth("hfp")
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> bluetooth("a2dp")
                AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> bluetooth("le_audio")
                else -> AudioRoute()
            }
        }
        // Before Android 12 there is no single "current device"; the accessory name is not available either.
        @Suppress("DEPRECATION")
        when {
            audio.isBluetoothScoOn -> AudioRoute("bluetooth", "", "hfp")
            audio.isSpeakerphoneOn -> AudioRoute("speaker")
            audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET || it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
            } -> AudioRoute("wired")
            else -> AudioRoute("earpiece")
        }
    }.getOrDefault(AudioRoute())
}
