buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath(libs.kotlin.gradle) }
}
plugins { alias(libs.plugins.android.application) apply false; id("com.android.library") version "9.4.1" apply false; id("org.jetbrains.kotlin.plugin.serialization") version "2.4.21" apply false; alias(libs.plugins.compose) apply false }
