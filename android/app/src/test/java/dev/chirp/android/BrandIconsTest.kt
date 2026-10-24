package dev.chirp.android

import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BrandIconsTest {
    @Test fun `the app is called Chirp and only the input method Chirp Keyboard`() {
        val app = RuntimeEnvironment.getApplication()
        assertEquals("Chirp", app.packageManager.getApplicationLabel(app.applicationInfo).toString())
        val launcher = app.packageManager.getActivityInfo(ComponentName(app, SetupActivity::class.java), 0)
        assertEquals("Chirp", launcher.loadLabel(app.packageManager).toString())
        val ime = app.packageManager.getServiceInfo(ComponentName(app, ChirpImeService::class.java), 0)
        assertEquals("Chirp Keyboard", ime.loadLabel(app.packageManager).toString())
        assertEquals("dev.chirp.android", app.packageName)
    }

    @Test fun `launcher settings and IME picker all resolve the selected adaptive bird`() {
        val app = RuntimeEnvironment.getApplication()
        assertEquals(R.mipmap.ic_launcher, app.applicationInfo.icon)
        val service = app.packageManager.getServiceInfo(ComponentName(app, ChirpImeService::class.java), 0)
        assertEquals(R.mipmap.ic_launcher, service.icon)
        for (id in listOf(R.mipmap.ic_launcher, helium314.keyboard.latin.R.mipmap.ic_launcher_round)) {
            val drawable = app.getDrawable(id)
            assertTrue(drawable is AdaptiveIconDrawable)
            val icon = drawable as AdaptiveIconDrawable
            assertNotNull(icon.background); assertNotNull(icon.foreground)
            if (Build.VERSION.SDK_INT >= 33) assertNotNull(icon.monochrome)
            val bitmap = Bitmap.createBitmap(108, 108, Bitmap.Config.ARGB_8888)
            icon.setBounds(0, 0, 108, 108); icon.draw(Canvas(bitmap))
            val pixels = IntArray(108 * 108); bitmap.getPixels(pixels, 0, 108, 0, 0, 108, 108)
            // The approved orange koi bird and yellow moon must survive Android's mask.
            assertTrue(pixels.any { Color.red(it) > 210 && Color.green(it) in 70..190 && Color.blue(it) < 100 })
            assertTrue(pixels.any { Color.red(it) > 220 && Color.green(it) > 180 && Color.blue(it) < 170 })
            bitmap.recycle()
        }
    }
    @Test fun `status glyph has transparent padding and a visible white bird alpha mask`() {
        val app = RuntimeEnvironment.getApplication()
        val icon = app.getDrawable(R.drawable.ic_chirp_notification)!!
        val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        icon.setBounds(0, 0, 96, 96); icon.draw(Canvas(bitmap))
        assertEquals(0, Color.alpha(bitmap.getPixel(0, 0)))
        assertTrue(Color.alpha(bitmap.getPixel(48, 48)) > 200)
        assertEquals(0x00ffffff, bitmap.getPixel(48, 48) and 0x00ffffff)
        bitmap.recycle()
    }
}
