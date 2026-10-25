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

/** #184: at 200% font the widget's labels shrink to fit on one line instead of wrapping mid-word (needs real text metrics). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "mdpi")
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class ChirpWidgetFontTest {
    private fun labelsFit(font: Float, cellWidthDp: Int, minWidth: Int) {
        val configuration = android.content.res.Configuration(RuntimeEnvironment.getApplication().resources.configuration).apply { fontScale = font }
        val context = RuntimeEnvironment.getApplication().createConfigurationContext(configuration)
        // What the Pixel launcher gave the real widget: ~83 dp tall, 8 dp padding, one cell wide or two.
        val width = cellWidthDp; val height = 83
        val root = ChirpWidgetProvider.views(context, minWidth).apply(context, FrameLayout(context))
        root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, width, height)
        listOf(R.id.widget_dictate, R.id.widget_record).map { root.findViewById<Button>(it) }.filter { it.visibility == View.VISIBLE }.forEach { button ->
            val layout = button.layout
            assertEquals("${button.text} stays on one line at font $font", 1, layout.lineCount)
            assertTrue("${button.text} fits its button at font $font", layout.getLineWidth(0) <= button.width - button.paddingLeft - button.paddingRight + 1f)
            assertTrue("${button.text} keeps a 48 dp hit rectangle", button.width >= 48 && button.height >= 48)
        }
    }
    @Test fun `one cell at 200 percent font`() = labelsFit(2f, 81, 80)
    @Test fun `two cells at 200 percent font`() = labelsFit(2f, 176, 176)
    @Test fun `two cells at the default font`() = labelsFit(1f, 176, 176)
}

