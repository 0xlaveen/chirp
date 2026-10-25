package dev.chirp.android

import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import android.provider.Settings
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class AccessibilitySettingsTest {
    @Test fun `a resolved but restricted service detail falls back to general Accessibility settings`() {
        val app = RuntimeEnvironment.getApplication()
        val details = "android.settings.ACCESSIBILITY_DETAILS_SETTINGS"
        shadowOf(app.packageManager).addResolveInfoForIntent(Intent(details), ResolveInfo().apply {
            activityInfo = ActivityInfo().apply { packageName = "com.android.settings"; name = "Details" }
        })
        for (failure in listOf(SecurityException("Restricted system activity"), android.content.ActivityNotFoundException())) {
            val launched = mutableListOf<String?>()
            val context = object : ContextWrapper(app) {
                override fun startActivity(intent: Intent) {
                    launched += intent.action
                    if (intent.action == details) throw failure
                }
            }
            openAccessibilitySettings(context)
            assertEquals(listOf(details, Settings.ACTION_ACCESSIBILITY_SETTINGS), launched)
        }
    }
}
