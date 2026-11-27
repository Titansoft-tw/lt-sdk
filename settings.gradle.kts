pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "lt-sdk"
include(":lt-device-info-android")
include(":lt-telemetry-android")
include(":lt-error-guard-android")
include(":lt-error-guard-sentry-android")
