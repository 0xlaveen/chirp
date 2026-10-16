buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath(libs.kotlin.gradle) }
}
plugins { alias(libs.plugins.android.application) apply false }
