plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android {
    namespace = "com.tswork.lt.errorguard.sentry"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    publishing { singleVariant("release") { withSourcesJar() } }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api(project(":lt-error-guard-android"))
    // The app brings its own Sentry (sentry-android pulls io.sentry:sentry); compiled against the oldest 8.x we support.
    compileOnly("io.sentry:sentry:8.0.0")
    testImplementation("io.sentry:sentry:8.63.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "lt-error-guard-sentry-android"
            }
        }
    }
}
