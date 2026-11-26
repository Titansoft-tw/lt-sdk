package com.tswork.lt.telemetry

import com.tswork.lt.deviceinfo.AudioRoute
import com.tswork.lt.deviceinfo.DeviceState
import com.tswork.lt.deviceinfo.NetworkSnapshot
import com.tswork.lt.deviceinfo.Thermal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The SDK's own enums against the generated contract (lt-telemetry-contract/contract.json). */
class ContractTest {
    @Test fun enumsMatchTheContract() {
        assertEquals(Contract.ERROR_DOMAINS, ErrorDomain.entries.map { it.code })
        assertEquals(Contract.APP_SETUP_STAGES, SetupStage.entries.map { it.code })
        assertEquals(Contract.LABELS.getValue("mic"), MicEvent.entries.map { it.reason })
        assertEquals(Contract.SEVERITIES, listOf(Severity.INFO, Severity.WARN, Severity.ERROR, Severity.FATAL))
        assertEquals(Contract.THERMAL_LEVELS, (0..3).map(Thermal::name))
        assertEquals(Contract.LABELS.getValue("fgs"), listOf(Fgs.STARTED, Fgs.START_DENIED, Fgs.STOPPED))
        for (body in listOf(Telemetry.QUALITY_SECOND, Telemetry.SDK_EVENT, Telemetry.APP_ERROR)) assertTrue(body, body in Contract.BODIES)
    }

    @Test fun contextBuildsFromTheDeviceInfoReaders() {
        val net = NetworkSnapshot(netType = "wifi", netTypeOs = "wifi", carrier = "CHT", country = "TW", vpn = "0", exitCountry = "TW",
            signal = mapOf("wifi_rssi_dbm" to "-60"))
        val c = TelemetryContext(net, AudioRoute("bluetooth", "AirPods", "hfp"), DeviceState(batteryPct = 50), netTypeSdk = "4g")
        assertEquals(TelemetryContext(netType = "wifi", carrier = "CHT", country = "TW", audioRoute = "bluetooth", audioDevice = "AirPods",
            btProfile = "hfp", vpn = "0", netTypeOs = "wifi", netTypeSdk = "4g", exitCountry = "TW",
            signal = mapOf("wifi_rssi_dbm" to "-60"), device = DeviceState(batteryPct = 50)), c)
    }
}
