// Chirp adapter build. Vendored upstream build scripts are retained unmodified.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.serialization")
    alias(libs.plugins.compose)
}
android {
    namespace = "helium314.keyboard.latin"
    compileSdk = 37
    defaultConfig {
        minSdk = 31
        // HeliBoard uses these app constants from its JNI/settings code.
        buildConfigField("String", "APPLICATION_ID", "\"dev.chirp.android\"")
        buildConfigField("String", "VERSION_NAME", "\"0.3.0 (HeliBoard 4.2)\"")
        buildConfigField("int", "VERSION_CODE", "3")
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    buildTypes { debug { isJniDebuggable = false } }
    buildFeatures { viewBinding = true; buildConfig = true; compose = true }
    externalNativeBuild { ndkBuild { path = file("upstream/app/src/main/jni/Android.mk") } }
    ndkVersion = "28.0.13004108"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Upstream predates Chirp's lint/toolchain. Exceptions remain scoped to this module.
    lint { abortOnError = false; checkReleaseBuilds = false }
    // AGP 9.4.1/Kotlin 2.4.21 FIR crashes while analyzing upstream AccessibilityLongPressTimer.
    // Run strict lint on Chirp; skip only analysis tasks in this vendored adapter module.
    tasks.matching { it.name.startsWith("lint") && it.name.contains("Analyze") }.configureEach { enabled = false }
}
dependencies {
    implementation(libs.core)
    implementation("androidx.recyclerview:recyclerview:1.4.0")
    implementation("androidx.autofill:autofill:1.3.0")
    implementation("androidx.viewpager2:viewpager2:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.navigation:navigation-compose:2.9.8")
    implementation("sh.calvin.reorderable:reorderable:3.1.0")
    implementation("com.github.skydoves:colorpicker-compose:1.1.3")
}
