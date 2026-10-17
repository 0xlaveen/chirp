package dev.chirp.android

import android.annotation.SuppressLint
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Local only. Never serialize Throwable.toString/message, thread names, filenames or app logs. */
internal class CrashLog(context: Context) {
    private val prefs = context.getSharedPreferences("crash_diagnostics", Context.MODE_PRIVATE)
    @SuppressLint("UseKtx") // Synchronous bounded write before the process terminates.
    @Synchronized fun record(error: Throwable, time: Long = System.currentTimeMillis()) {
        val entry = JSONObject().put("time", time).put("version", BuildConfig.VERSION_NAME)
            .put("versionCode", BuildConfig.VERSION_CODE).put("exception", identifier(error.javaClass.name))
        val frames = JSONArray()
        error.stackTrace.take(48).forEach { frame ->
            frames.put(JSONObject().put("class", identifier(frame.className))
                .put("method", identifier(frame.methodName)).put("line", frame.lineNumber))
        }
        entry.put("frames", frames)
        val old = entries()
        val next = JSONArray()
        (maxOf(0, old.length() - 4) until old.length()).forEach { next.put(old.getJSONObject(it)) }
        next.put(entry)
        check(prefs.edit().putString("entries", next.toString()).commit())
    }
    private fun identifier(value: String) = value.take(240).filter { it.isLetterOrDigit() || it in ".$<>_" }
    private fun entries(): JSONArray = try { JSONArray(prefs.getString("entries", "[]")) } catch (_: Exception) { JSONArray() }
    fun text(): String = entries().let { if (it.length() == 0) "No crashes recorded" else it.toString(2) }
    fun install(previous: Thread.UncaughtExceptionHandler? = Thread.getDefaultUncaughtExceptionHandler()): Thread.UncaughtExceptionHandler {
        val handler = Thread.UncaughtExceptionHandler { thread, error ->
            try { record(error) } catch (_: Throwable) { /* Crash handling must not prevent process termination. */ }
            previous?.uncaughtException(thread, error)
        }
        Thread.setDefaultUncaughtExceptionHandler(handler)
        return handler
    }
}
