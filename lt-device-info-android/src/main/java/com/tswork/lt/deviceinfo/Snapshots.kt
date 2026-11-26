package com.tswork.lt.deviceinfo

/** Read once per process: these do not change while the app runs. */
data class StaticDevice(
    val platform: String,
    val osVersion: String,
    val appVersion: String,
    /** Manufacturer and model, e.g. "Google Pixel 3a XL"; never the user-given device name. */
    val model: String,
    /** Build.MANUFACTURER ("Google", "samsung"); iOS "Apple". */
    val brand: String,
)

/** The network right now. Blank means unknown. */
data class NetworkSnapshot(
    /** wifi / 5g / 4g / 3g / 2g / cellular / ethernet / other / none; under a VPN the link underneath. */
    val netType: String = "",
    /** Contract values only (wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown): what the OS says. */
    val netTypeOs: String = "",
    val carrier: String = "",
    val country: String = "",
    /** "1" while a VPN carries the traffic, "0" without one, blank if unknown. */
    val vpn: String = "",
    /** Country the traffic exits from, as [AndroidDeviceInfo]'s exit country lookup reported it. */
    val exitCountry: String = "",
    /** Radio levels only, keys already final (wifi_rssi_dbm, cell_rsrp_dbm, ...); never SSIDs, cell ids or location. */
    val signal: Map<String, String> = emptyMap(),
)

/** Route, accessory model and Bluetooth profile of the device call audio is on; blank = unknown or not applicable. */
data class AudioRoute(
    /** speaker / earpiece / wired / bluetooth. */
    val route: String = "",
    /** Already passed through [deviceModel]; blank for the built-in speaker and earpiece. */
    val device: String = "",
    /** hfp / a2dp / le_audio, only on bluetooth. */
    val btProfile: String = "",
)

/**
 * Accessory names are user-editable and usually start with the owner ("小明的 AirPods",
 * "Jason's AirPods Pro"). Only what follows the possessive is kept, so the model survives
 * and the name does not leave the device.
 */
fun deviceModel(name: String?): String =
    name.orEmpty().replace(Regex("^.*(['’]s|的)\\s*"), "").filter { it >= ' ' && it != '\u007f' }.trim().take(48)
