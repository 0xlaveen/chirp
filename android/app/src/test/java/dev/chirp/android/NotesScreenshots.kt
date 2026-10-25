package dev.chirp.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.test.platform.app.InstrumentationRegistry

/**
 * Material's sheet window does not implement DialogWindowProvider. Compose's PixelCopy helper consequently captures
 * the activity underneath it on Robolectric. Draw the actual sheet root over that activity for these review artifacts.
 */
internal fun notesScreenshot(target: SemanticsNodeInteraction, sheet: Boolean): Bitmap {
    val background = target.captureToImage().asAndroidBitmap()
    if (!sheet) return background
    val view = (target.fetchSemanticsNode().root as ViewRootForTest).view
    val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        val canvas = Canvas(bitmap)
        canvas.drawBitmap(background, 0f, 0f, null)
        view.draw(canvas)
    }
    return bitmap
}
