package com.tswork.lt.deviceinfo

/** `net_type_os`: wifi / 2g / 3g / 4g / 5g / ethernet / none / unknown. */
object OsNetType {
    private val CONTRACT = setOf("wifi", "2g", "3g", "4g", "5g", "ethernet", "none")
    /** Collapses the app's own net_type vocabulary ("cellular", "other") onto the contract values. */
    fun normalize(value: String) = value.takeIf { it in CONTRACT } ?: "unknown"
    private val GENERATIONS = setOf("2g", "3g", "4g", "5g")
    /** The Lab check's network: on cellular the OS's generation when known, as net_type needs a permission and misses 5G NSA. */
    fun effective(netType: String, netTypeOs: String) =
        if ((netType == "cellular" || netType in GENERATIONS) && netTypeOs in GENERATIONS) netTypeOs else netType

    /**
     * Android cellular generation from TelephonyDisplayInfo (what the status bar shows, no permission
     * needed on Android 12+) or TelephonyManager.dataNetworkType. 5G NSA reports LTE as the network
     * type with an NR override, which is why the override is checked first.
     */
    fun cellular(networkType: Int?, overrideType: Int?): String {
        when (overrideType) {
            3, 4, 5 -> return "5g" // OVERRIDE_NETWORK_TYPE_NR_NSA, NR_NSA_MMWAVE, NR_ADVANCED
            1, 2 -> return "4g"    // LTE_CA, LTE_ADVANCED_PRO
        }
        return when (networkType) {
            20 -> "5g"                                   // NR (SA)
            13, 18 -> "4g"                               // LTE, IWLAN
            3, 8, 9, 10, 15, 5, 6, 12, 14, 17 -> "3g"    // UMTS, HSDPA, HSUPA, HSPA, HSPAP, EVDO_0/A/B, EHRPD, TD_SCDMA
            1, 2, 4, 7, 16 -> "2g"                       // GPRS, EDGE, CDMA, 1xRTT, GSM
            else -> "unknown"
        }
    }
}
