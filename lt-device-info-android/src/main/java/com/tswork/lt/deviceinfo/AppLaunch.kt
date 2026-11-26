package com.tswork.lt.deviceinfo

/** `app_launch` on push_received / app_woken. */
object AppLaunch {
    const val COLD = "cold"
    const val BACKGROUND = "background"
    const val FOREGROUND = "foreground"
}

/**
 * Classifies each push by the app's state when it arrived: foreground = the app is in front now;
 * cold = the first push this process handles and no Activity/scene was ever in front in it
 * (the push started the process); anything else background. One per process.
 */
class AppLaunchTracker {
    private var everForeground = false
    private var pushes = 0

    fun foreground() { everForeground = true }

    fun classify(foreground: Boolean?): String {
        val first = pushes++ == 0
        return when {
            foreground == true -> AppLaunch.FOREGROUND
            first && !everForeground -> AppLaunch.COLD
            else -> AppLaunch.BACKGROUND
        }
    }
}
