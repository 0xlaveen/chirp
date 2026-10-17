package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class CrashLogTest {
    @Test fun `crash ring survives reload is bounded and excludes messages filenames and causes`() {
        val context = RuntimeEnvironment.getApplication()
        val log = CrashLog(context)
        for (i in 1..7) {
            val error = IllegalStateException("synthetic secret token transcript $i", RuntimeException("synthetic private cause"))
            error.stackTrace = arrayOf(StackTraceElement("dev.chirp.android.Synthetic", "editor", "synthetic-secret-file", i))
            log.record(error, i.toLong())
        }
        val text = CrashLog(context).text()
        val entries = org.json.JSONArray(text)
        assertEquals(5, entries.length())
        assertEquals(3L, entries.getJSONObject(0).getLong("time"))
        assertTrue(text.contains("java.lang.IllegalStateException"))
        assertTrue(text.contains("dev.chirp.android.Synthetic"))
        assertFalse(text.contains("secret")); assertFalse(text.contains("transcript")); assertFalse(text.contains("cause"))
    }
    @Test fun `uncaught handler records then delegates original throwable without replacing it`() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        val error = IllegalArgumentException("synthetic private message")
        var delegated: Throwable? = null
        try {
            val handler = CrashLog(RuntimeEnvironment.getApplication()).install { _, value -> delegated = value }
            handler.uncaughtException(Thread.currentThread(), error)
            assertSame(error, delegated)
            assertTrue(CrashLog(RuntimeEnvironment.getApplication()).text().contains("IllegalArgumentException"))
            assertFalse(CrashLog(RuntimeEnvironment.getApplication()).text().contains("synthetic private message"))
        } finally { Thread.setDefaultUncaughtExceptionHandler(previous) }
    }
}
