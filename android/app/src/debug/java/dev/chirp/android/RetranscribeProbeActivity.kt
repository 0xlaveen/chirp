package dev.chirp.android

import android.app.Activity
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject

/** Synthetic emulator fixtures only. Compiled out of release; emits counts/booleans, never text or pairing. */
class RetranscribeProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = JSONObject()
        try {
            val model = requireNotNull(NotesSessionHolder.current)
            if (intent.getStringExtra("operation") == "corrupt") {
                val doc = model.document
                val people = doc.roster.people
                val first = doc.segments.firstOrNull { !it.turns.isNullOrEmpty() }
                if (people.size > 1 && first != null) model.reassignTurn(first.id, 0, people.last().id)
                val json = doc.toJson()
                val rows = json.getJSONArray("segments")
                for (i in 0 until rows.length()) rows.getJSONObject(i).apply {
                    put("text", "WRONG TEXT"); put("raw", "WRONG TEXT")
                    optJSONArray("turns")?.let { turns -> for (j in 0 until turns.length()) turns.getJSONObject(j).put("text", "WRONG TEXT").put("raw", "WRONG TEXT") }
                }
                model.recorder.restore(NotesDocument.fromJson(json), model.elapsed)
                model.keepSession()
                baseline = identity(model.document)
                body = model.document.text
                noteTitle = model.document.name
            }
            val doc = model.document
            result.put("ok", true).put("segments", doc.segments.size).put("clips", doc.audio.size)
                .put("wrong", doc.segments.all { it.raw == "WRONG TEXT" })
                .put("updated", doc.segments.any { !it.isGap && it.raw.isNotBlank() && it.raw != "WRONG TEXT" })
                .put("fixture_words", doc.segments.any { segment -> listOf("synthetic keyboard", "draft tomorrow", "ship the beta", "spec tomorrow").any { segment.raw.lowercase().contains(it) } })
                .put("identity_preserved", baseline == identity(doc)).put("body_preserved", body == doc.text).put("title_preserved", noteTitle == doc.name)
                .put("overrides", doc.segments.sumOf { it.turns.orEmpty().count { turn -> turn.overridePerson != null } })
                .put("previous", doc.previousTranscript != null)
                .put("scratch_empty", java.io.File(noBackupFilesDir, "notes_scratch").listFiles().isNullOrEmpty() && java.io.File(cacheDir, "notes_scratch").listFiles().isNullOrEmpty() && java.io.File(filesDir, "notes_scratch").listFiles().isNullOrEmpty())
        } catch (_: Exception) { result.put("ok", false) }
        java.io.File(filesDir, "retranscribe-probe.json").writeText(result.toString())
        finish()
    }

    private fun identity(doc: NotesDocument) = JSONObject().put("people", doc.roster.toJson()).put("turns", JSONArray().apply {
        doc.segments.forEach { segment -> put(JSONArray().apply { segment.turns.orEmpty().forEach { turn ->
            put(JSONObject().put("person", turn.person).put("start", turn.start).put("override", turn.overridePerson))
        } }) }
    }).toString()

    companion object {
        private var baseline: String? = null
        private var body: String? = null
        private var noteTitle: String? = null
    }
}
