# Chirp app rules (HeliBoard's upstream rules are applied too; see build.gradle.kts).

# ML Kit code scanner (Google Play services) builds its components by reflection through
# component registrars. R8 full mode otherwise merges or strips them, and "Scan pairing QR" crashes
# in release builds with an NPE in com.google.android.gms.internal.mlkit_code_scanner.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.firebase.components.** { *; }
