package dev.chirp.android

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ChirpWidgetTest {
    private val app get() = RuntimeEnvironment.getApplication()
    class TestTile : DictateTileService() {
        var opened: PendingIntent? = null
        var unlocks = 0
        override fun locked() = true
        override fun unlock(then: Runnable) { unlocks++; then.run() }
        override fun open(intent: Intent, pending: PendingIntent) { opened = pending }
    }
    @Test fun `Dictate tile unlocks and opens clipboard mode with no data`() {
        val tile = Robolectric.buildService(TestTile::class.java).create().get()
        tile.onClick(); tile.onStartListening()
        assertEquals(1, tile.unlocks)
        val launch = shadowOf(tile.opened!!)
        assertEquals(QuickDictateActivity::class.java.name, launch.savedIntent.component!!.className)
        assertTrue(launch.flags and PendingIntent.FLAG_IMMUTABLE != 0)
        assertNull(launch.savedIntent.extras); assertNull(launch.savedIntent.data)
    }
    @Test fun `widget pending intents open Dictate and Notes recording and one cell hides Record`() {
        val views = ChirpWidgetProvider.views(app, 160).apply(app, FrameLayout(app))
        views.findViewById<Button>(R.id.widget_dictate).performClick()
        val dictate = shadowOf(app).nextStartedActivity
        assertEquals(QuickDictateActivity::class.java.name, dictate.component!!.className)
        assertNull(dictate.extras)
        views.findViewById<Button>(R.id.widget_record).performClick()
        val record = shadowOf(app).nextStartedActivity
        assertEquals(NotesActivity::class.java.name, record.component!!.className)
        assertEquals(NotesService.ACTION_RECORD, record.action)
        assertNull(record.getStringExtra(Intent.EXTRA_TEXT))
        val small = ChirpWidgetProvider.views(app, 80).apply(app, FrameLayout(app))
        assertEquals(View.GONE, small.findViewById<View>(R.id.widget_record).visibility)
        assertEquals("Dictate", small.findViewById<Button>(R.id.widget_dictate).text.toString())
        val info = app.packageManager.getReceiverInfo(android.content.ComponentName(app, ChirpWidgetProvider::class.java), android.content.pm.PackageManager.GET_META_DATA)
        val xml = app.resources.getXml(info.metaData.getInt("android.appwidget.provider"))
        while (xml.next() != org.xmlpull.v1.XmlPullParser.START_TAG) { }
        assertEquals(0, xml.getAttributeIntValue("http://schemas.android.com/apk/res/android", "updatePeriodMillis", -1))
    }
    @Test fun `add tile and widget provide instructions on unsupported systems`() {
        val request = DictationEntryRequests(app)
        if (android.os.Build.VERSION.SDK_INT < 33) assertTrue(request.tile(false).contains("Swipe down twice"))
        assertTrue(request.widget().contains("Widgets"))
    }
}
