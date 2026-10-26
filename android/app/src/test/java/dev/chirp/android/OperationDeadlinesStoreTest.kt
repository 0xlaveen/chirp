package dev.chirp.android

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class OperationDeadlinesStoreTest {
    @Test fun `health cache retains deadlines for dictation entry points across recreation`() {
        val context = RuntimeEnvironment.getApplication()
        val store = SettingsStore(context)
        store.health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"operation_deadlines":{"dictation":30,"notes_structure":90}}""")
        val cached = SettingsStore(context).health!!.operationDeadlines
        assertEquals(35000L, cached.timeoutMs("dictation", 12000))
        assertEquals(95000L, cached.timeoutMs("notes_structure", 35000))
        assertEquals(50000L, cached.timeoutMs("notes_reorganize", 50000))
    }
}
