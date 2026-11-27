plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android {
    namespace = "com.tswork.lt.errorguard"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    publishing { singleVariant("release") { withSourcesJar() } }
}

// VectorsTest reads the shared spec; without this Gradle would skip the tests as up to date after a vector changes.
tasks.withType<Test>().configureEach {
    inputs.dir(rootProject.file("lt-error-guard-spec")).withPathSensitivity(PathSensitivity.RELATIVE)
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    testImplementation("junit:junit:4.13.2")
    // org.json ships with Android; local unit tests only see android.jar's stubs, so they get the real one.
    testImplementation("org.json:json:20240303")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "lt-error-guard-android"
            }
        }
    }
}
