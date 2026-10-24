package dev.chirp.android

import android.content.Context
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject

/**
 * One Notes session in numbers only (no text, audio, names or hosts): how long it recorded, how long the screen was off,
 * segments and gaps, structure/reorganize calls, and how many screen updates ran or were skipped by the battery saver.
 */
internal data class NotesTiming(val time: Long, val recordedS: Int, val screenOffS: Int, val segments: Int, val gaps: Int, val passes: Int,
                                val updates: Int, val skipped: Int, val saver: Boolean, val problem: String? = null)

/** Counts one session from Record to its end; main thread. */
internal class NotesSessionCounter(private val now: () -> Long, private val recorder: NotesRecorder, private val saver: Boolean) {
    private val startPasses = recorder.passes
    private val startSegments = recorder.document.segments.size
    private val startRecorded = recorder.elapsed
    private var offMs = 0L
    private var offSince: Long? = null
    var updates = 0
    var skipped = 0

    fun quiet(on: Boolean) {
        if (on) { if (offSince == null) offSince = now() } else offSince?.let { offMs += now() - it; offSince = null }
    }

    fun finish(time: Long): NotesTiming {
        quiet(false)
        val added = recorder.document.segments.drop(startSegments)
        return NotesTiming(time, (recorder.elapsed - startRecorded).toInt(), (offMs / 1000).toInt(), added.size, added.count { it.isGap },
            recorder.passes - startPasses, updates, skipped, saver, recorder.problem)
    }
}

/** The last [MAX] Notes sessions, in the same private, backup-excluded preferences as the dictation timings. */
internal class NotesTimingLog(context: Context) {
    private val prefs = context.getSharedPreferences("session_timings", Context.MODE_PRIVATE)
    @Synchronized fun record(entry: NotesTiming) { prefs.edit { putString(KEY, encode((entries() + entry).takeLast(MAX))) } }
    @Synchronized fun entries(): List<NotesTiming> = decode(prefs.getString(KEY, null))
    @Synchronized fun clear() { prefs.edit { remove(KEY) } }

    /** Diagnostics: one line per session, newest first. */
    fun summary(): String = entries().asReversed().take(5).joinToString("\n") { t ->
        "${t.recordedS / 60} min recorded (${t.screenOffS / 60} min screen off), ${t.segments} segments, ${t.gaps} gaps, ${t.passes} notes calls, " +
            "${t.updates} screen updates, ${t.skipped} skipped" + (if (t.saver) " · battery saver" else "") + (t.problem?.let { " · last problem: $it" } ?: "")
    }.ifEmpty { "No Notes sessions yet" }

    companion object {
        const val MAX = 20
        private const val KEY = "notes"
        fun encode(items: List<NotesTiming>): String = JSONArray().also { array ->
            items.forEach { t ->
                array.put(JSONObject().put("t", t.time).put("rec", t.recordedS).put("off", t.screenOffS).put("seg", t.segments).put("gap", t.gaps)
                    .put("pass", t.passes).put("up", t.updates).put("skip", t.skipped).put("saver", t.saver).put("why", t.problem))
            }
        }.toString()
        fun decode(raw: String?): List<NotesTiming> = try {
            val array = JSONArray(raw ?: "[]")
            (0 until array.length()).mapNotNull { i ->
                try {
                    val o = array.getJSONObject(i)
                    NotesTiming(o.getLong("t"), o.getInt("rec"), o.getInt("off"), o.getInt("seg"), o.getInt("gap"), o.getInt("pass"),
                        o.getInt("up"), o.getInt("skip"), o.getBoolean("saver"), o.text("why"))
                } catch (_: Exception) { null }
            }
        } catch (_: Exception) { emptyList() }
    }
}
