package dev.chirp.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue

/**
 * Draw the actual Compose root over PixelCopy's buffer: Robolectric can return the activity under a sheet/dialog,
 * or a blank buffer for the first frame. Check visible content before exporting these review artifacts.
 */
internal fun notesScreenshot(target: SemanticsNodeInteraction): Bitmap {
    val background = target.captureToImage().asAndroidBitmap()
    val view = (target.fetchSemanticsNode().root as ViewRootForTest).view
    val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        val canvas = Canvas(bitmap)
        canvas.drawBitmap(background, 0f, 0f, null)
        view.draw(canvas)
    }
    val first = bitmap.getPixel(0, 0)
    assertTrue("Notes capture is blank", (0 until bitmap.height step 7).any { y ->
        (0 until bitmap.width step 7).any { x -> bitmap.getPixel(x, y) != first }
    })
    return bitmap
}
