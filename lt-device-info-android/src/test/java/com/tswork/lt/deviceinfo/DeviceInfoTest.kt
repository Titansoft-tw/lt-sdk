package com.tswork.lt.deviceinfo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceInfoTest {
    @Test fun accessoryNamesLoseTheOwner() {
        assertEquals("AirPods Pro", deviceModel("Jason's AirPods Pro"))
        assertEquals("AirPods Pro", deviceModel("Jason’s AirPods Pro"))
        assertEquals("AirPods", deviceModel("小明的 AirPods"))
        assertEquals("WH-1000XM5", deviceModel("WH-1000XM5"))
        assertEquals("", deviceModel(null))
    }

    @Test fun thermalLevelsAndExitReasonsHaveContractNames() {
        // Android 7 thermal levels onto the contract's 4 (0 nominal, 1 fair, 2 serious, 3 critical).
        assertEquals(listOf(0, 1, 1, 2, 3, 3, 3), (0..6).map { Thermal.android(it) })
        assertNull(Thermal.android(-1))
        assertEquals(listOf("nominal", "fair", "serious", "critical"), (0..3).map { Thermal.name(it) })
        assertEquals("low_memory", ExitReasons.android(3))
        assertEquals("freezer", ExitReasons.android(14))
        assertEquals("user_requested", ExitReasons.android(10))
        assertEquals("signaled", ExitReasons.android(2))
        assertEquals("unknown", ExitReasons.android(0))
        assertEquals("reason_99", ExitReasons.android(99))
    }

    @Test fun theLabCheckUsesTheGenerationTheOsShowsOnCellularOnly() {
        assertEquals("4g", OsNetType.effective("cellular", "4g")) // No phone-state permission.
        assertEquals("5g", OsNetType.effective("4g", "5g"))       // 5G NSA: the data network type says LTE.
        assertEquals("cellular", OsNetType.effective("cellular", "unknown"))
        assertEquals("wifi", OsNetType.effective("wifi", "4g"))
        assertEquals("none", OsNetType.effective("none", ""))
    }

    @Test fun osNetTypeSeesFiveGNonStandaloneAndKeepsToContractValues() {
        assertEquals("5g", OsNetType.cellular(13, 3)) // LTE with the NR_NSA override: the status bar says 5G.
        assertEquals("5g", OsNetType.cellular(20, 0)) // NR standalone.
        assertEquals("4g", OsNetType.cellular(13, 0))
        assertEquals("4g", OsNetType.cellular(13, 1)) // LTE_CA
        assertEquals("3g", OsNetType.cellular(15, 0)) // HSPA+
        assertEquals("2g", OsNetType.cellular(2, 0))
        assertEquals("unknown", OsNetType.cellular(0, 0))
        assertEquals("unknown", OsNetType.cellular(null, null))
        assertEquals("unknown", OsNetType.normalize("cellular"))
        assertEquals("unknown", OsNetType.normalize("other"))
        assertEquals("wifi", OsNetType.normalize("wifi"))
        assertEquals("none", OsNetType.normalize("none"))
    }

    @Test fun pushesAreClassifiedByTheAppStateWhenTheyArrive() {
        val cold = AppLaunchTracker()
        assertEquals(AppLaunch.COLD, cold.classify(false))
        assertEquals(AppLaunch.BACKGROUND, cold.classify(false))
        assertEquals(AppLaunch.FOREGROUND, cold.classify(true))
        val shown = AppLaunchTracker().apply { foreground() }
        assertEquals(AppLaunch.BACKGROUND, shown.classify(null))
    }
}
