plugins {
    id("com.android.library") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
}

// JitPack passes -Pversion=<tag>; groupId is com.github.<owner>.<repo>, artifactId the module name.
subprojects {
    group = "com.github.Titansoft-tw.lt-sdk"
    if (version == Project.DEFAULT_VERSION) version = "0.0.0-SNAPSHOT"
}
