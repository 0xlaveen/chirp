plugins { alias(libs.plugins.android.application); alias(libs.plugins.compose) }
android {
    buildFeatures { compose = true; buildConfig = true }
    namespace = "dev.chirp.android"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    buildToolsVersion = "37.0.0"
    ndkVersion = "28.0.13004108"
    packaging { jniLibs { useLegacyPackaging = true } }
    defaultConfig {
        applicationId = "dev.chirp.android"
        minSdk = 31
        targetSdk = 37
        versionCode = 10
        versionName = "0.6.0"
    }
    signingConfigs {
        create("local") {
            storeFile = rootProject.file("keystore/local-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    // The dev-only key is per checkout (scripts/make-keystore.sh, gitignored); without it the release APK is unsigned.
    val localKeystore = rootProject.file("keystore/local-debug.keystore")
    if (localKeystore.exists()) buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("local")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), rootProject.file("keyboard/upstream/app/proguard-rules.pro"), "proguard-rules.pro")
        }
        release {
            signingConfig = signingConfigs.getByName("local")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), rootProject.file("keyboard/upstream/app/proguard-rules.pro"), "proguard-rules.pro")
        }
    }
    else logger.warn("keystore/local-debug.keystore missing: release APK will be unsigned (run scripts/make-keystore.sh)")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint { warningsAsErrors = true; lintConfig = file("lint.xml") }
    testOptions { unitTests.isIncludeAndroidResources = true }
    sourceSets.getByName("debug").res.directories.add(layout.buildDirectory.dir("generated/chirp-debug-res").get().asFile.path)
}
dependencies {
    implementation(project(":keyboard"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.material)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test)
    // Compose pulls Espresso 3.5; use stable 3.7 for modern InputManager APIs.
    testImplementation(libs.espresso.core)
    debugImplementation(libs.compose.ui.test.manifest)
    implementation(libs.okhttp)
    implementation(libs.core)
    implementation(libs.activity)
    implementation(libs.coroutines)
    implementation(libs.code.scanner)
    constraints {
        implementation(libs.fragment) { because("Play services brings an old Fragment incompatible with Activity Result APIs") }
    }
    testImplementation(libs.junit)
    testImplementation(libs.json)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.okhttp.tls)
    testImplementation(libs.robolectric)
}

// Opt-in live transport check against a running chirp-server (see README "JVM live check").
// Without -Pchirp.live.url the LiveServerTest is skipped.
tasks.withType<Test>().configureEach {
    systemProperty("chirp.screenshots", rootProject.file("../docs/screenshots/android").absolutePath)
    // Robolectric on JDK 17+: https://robolectric.org/getting-started/#running-with-java-17-and-higher
    jvmArgs(
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "--add-opens=java.base/java.io=ALL-UNNAMED",
        "--add-opens=java.base/java.net=ALL-UNNAMED",
        "--add-opens=java.base/java.security=ALL-UNNAMED",
        "--add-opens=java.base/java.text=ALL-UNNAMED",
        "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
        "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
        "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
    )
    listOf("chirp.live.url", "chirp.live.tokenFile", "chirp.live.wav", "chirp.live.expect").forEach { key ->
        providers.gradleProperty(key).orNull?.let { systemProperty(key, it) }
    }
}

val generateDebugSyntheticAudio by tasks.registering(Exec::class) {
    commandLine("sh", rootProject.file("scripts/make-synthetic-wav.sh"))
    outputs.dir(layout.buildDirectory.dir("generated/chirp-debug-assets"))
}
val generateEmulatorTls by tasks.registering(Exec::class) {
    outputs.upToDateWhen { false } // Renew the disposable test certificate before expiry.
    commandLine("sh", rootProject.file("scripts/make-emulator-tls.sh"))
    outputs.dir(layout.buildDirectory.dir("generated/chirp-debug-res"))
    outputs.dir(layout.buildDirectory.dir("emulator-tls"))
}
tasks.matching { it.name == "preDebugBuild" }.configureEach { dependsOn(generateEmulatorTls) }
tasks.matching { it.name == "mergeDebugAssets" || it.name == "packageDebugUnitTestForUnitTest" }.configureEach {
    dependsOn(generateDebugSyntheticAudio)
}
