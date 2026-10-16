plugins { alias(libs.plugins.android.application) }
android {
    namespace = "dev.chirp.android"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    buildToolsVersion = "37.0.0"
    defaultConfig {
        applicationId = "dev.chirp.android"
        minSdk = 31
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }
    signingConfigs {
        create("local") {
            storeFile = rootProject.file("keystore/local-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    buildTypes { release { signingConfig = signingConfigs.getByName("local") } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint { warningsAsErrors = true }
}
dependencies {
    implementation(libs.okhttp)
    implementation(libs.core)
    implementation(libs.activity)
    implementation(libs.coroutines)
    testImplementation(libs.junit)
    testImplementation(libs.json)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.okhttp.tls)
}

// Opt-in live transport check against a running chirp-server (see README "JVM live check").
// Without -Pchirp.live.url the LiveServerTest is skipped.
tasks.withType<Test>().configureEach {
    listOf("chirp.live.url", "chirp.live.tokenFile", "chirp.live.wav", "chirp.live.expect").forEach { key ->
        providers.gradleProperty(key).orNull?.let { systemProperty(key, it) }
    }
}
