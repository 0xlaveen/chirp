package dev.chirp.android

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 34, 37])
class ScratchpadTileTest {
    class TestTile : ScratchpadTileService() {
        var isLockedNow = false
        val opened = mutableListOf<Pair<Intent, PendingIntent>>()
        var unlocks = 0
        override fun locked() = isLockedNow
        override fun unlock(then: Runnable) { unlocks++; then.run() }
        override fun open(intent: Intent, pending: PendingIntent) { opened += intent to pending }
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private fun tile() = Robolectric.buildService(TestTile::class.java).create().get()

    @Test fun `tap opens the Scratchpad in its own task through an immutable pending intent`() {
        val tile = tile(); tile.onClick()
        val (intent, pending) = tile.opened.single()
        assertEquals(ScratchpadActivity::class.java.name, intent.component!!.className)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertNull(intent.getStringExtra(Intent.EXTRA_TEXT)); assertNull(intent.data)
        val saved = shadowOf(pending)
        assertTrue(saved.isActivityIntent)
        assertEquals(ScratchpadActivity::class.java.name, saved.savedIntent.component!!.className)
        assertTrue(saved.flags and PendingIntent.FLAG_IMMUTABLE != 0)
        assertEquals(0, tile.unlocks)
    }

    @Test fun `locked device asks for unlock before opening`() {
        val tile = tile().also { it.isLockedNow = true }
        tile.onClick()
        assertEquals(1, tile.unlocks); assertEquals(1, tile.opened.size)
    }

    @Test fun `listening without a bound tile is harmless`() { tile().onStartListening() }

    @Test fun `manifest declares a protected tile service and a private Scratchpad`() {
        val services = app.packageManager.queryIntentServices(Intent("android.service.quicksettings.action.QS_TILE").setPackage(app.packageName), 0)
        val info = services.single().serviceInfo
        assertEquals(ScratchpadTileService::class.java.name, info.name)
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", info.permission)
        assertTrue(info.exported)
        assertTrue(info.labelRes != 0 && info.icon != 0)
    }

    @Test fun `launcher shortcut targets the Scratchpad from the launcher activity`() {
        val meta = app.packageManager.getActivityInfo(ComponentName(app, SetupActivity::class.java), PackageManager.GET_META_DATA).metaData
        assertEquals(R.xml.shortcuts, meta.getInt("android.app.shortcuts"))
        val xml = app.resources.getXml(R.xml.shortcuts)
        val android = "http://schemas.android.com/apk/res/android"
        var id: String? = null; var target: String? = null; var pkg: String? = null; var action: String? = null
        while (xml.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            if (xml.eventType != org.xmlpull.v1.XmlPullParser.START_TAG) continue
            when (xml.name) {
                "shortcut" -> id = xml.getAttributeValue(android, "shortcutId")
                "intent" -> { target = xml.getAttributeValue(android, "targetClass"); pkg = xml.getAttributeValue(android, "targetPackage")
                    action = xml.getAttributeValue(android, "action") }
            }
        }
        assertEquals("scratchpad", id); assertEquals(ScratchpadActivity::class.java.name, target)
        assertEquals(app.packageName, pkg); assertEquals(Intent.ACTION_VIEW, action)
    }
}
