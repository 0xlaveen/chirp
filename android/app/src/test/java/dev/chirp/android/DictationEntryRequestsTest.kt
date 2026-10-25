package dev.chirp.android

import android.app.PendingIntent
import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Bundle
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Resetter
import org.robolectric.shadows.ShadowAppWidgetManager
import java.util.concurrent.Executor
import java.util.function.Consumer

@Implements(StatusBarManager::class)
class EntryStatusBarShadow {
    @Implementation(minSdk = 33)
    protected fun requestAddTileService(component: ComponentName, label: CharSequence, icon: Icon, executor: Executor, result: Consumer<Int>) {
        requested = component; title = label.toString()
        executor.execute { result.accept(StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED) }
    }
    companion object {
        var requested: ComponentName? = null
        var title: String? = null
        @JvmStatic @Resetter fun reset() { requested = null; title = null }
    }
}

@Implements(AppWidgetManager::class)
class EntryWidgetShadow : ShadowAppWidgetManager() {
    @Implementation override fun requestPinAppWidget(provider: ComponentName, extras: Bundle?, callback: PendingIntent?): Boolean {
        requested = provider; supplied = extras
        return true
    }
    companion object {
        var requested: ComponentName? = null
        var supplied: Bundle? = null
        @JvmStatic @Resetter fun resetRequests() { requested = null; supplied = null }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], shadows = [EntryStatusBarShadow::class, EntryWidgetShadow::class])
class DictationEntryRequestsTest {
    @Test fun `settings requests the two protected tiles and pins only the static widget`() {
        val app = RuntimeEnvironment.getApplication()
        val requests = DictationEntryRequests(app)
        requests.tile(false)
        assertEquals(ComponentName(app, DictateTileService::class.java), EntryStatusBarShadow.requested)
        assertEquals("Dictate", EntryStatusBarShadow.title)
        requests.tile(true)
        assertEquals(ComponentName(app, NotesTileService::class.java), EntryStatusBarShadow.requested)
        assertEquals("Notes", EntryStatusBarShadow.title)
        org.robolectric.Shadows.shadowOf(app.getSystemService(AppWidgetManager::class.java)).setRequestPinAppWidgetSupported(true)
        requests.widget()
        assertEquals(ComponentName(app, ChirpWidgetProvider::class.java), EntryWidgetShadow.requested)
        assertNull(EntryWidgetShadow.supplied)
    }
}
