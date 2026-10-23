package dev.chirp.android

import android.content.Context
import android.os.UserManager
import androidx.core.content.edit
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/** One kept Notes session. Deliberately not a data class: toString must never expose notes text. */
internal class NotesSessionEntry(val id: String, val time: Long, val title: String, val chars: Int, val document: JSONObject) {
    override fun toString() = "NotesSessionEntry(<redacted>)"
}

/**
 * "Keep notes on this phone": opt-in, like dictation history. Each session (notes, transcript, name, elapsed audio) is
 * kept in one file sealed with its own Android Keystore key in credential-encrypted app storage, excluded from backup
 * and transfer, pruned to the history retention choices. Turning it off deletes the file and the key. Never logged.
 */
internal class NotesSessions(
    context: Context,
    private val keys: HistoryKeys = KeystoreKeys(ALIAS),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val app = context.applicationContext ?: context
    private val prefs = app.getSharedPreferences("chirp_notes_sessions", Context.MODE_PRIVATE)
    private val sealed = SealedFile(File(app.filesDir, FILE_NAME), keys, byteArrayOf('C'.code.toByte(), 'S'.code.toByte(), 1))

    val enabled get() = prefs.getBoolean("enabled", false)
    var retention: HistoryRetention
        get() = HistoryRetention.of(prefs.getInt("retention_days", HistoryRetention.WEEK.days))
        set(value) { prefs.edit { putInt("retention_days", value.days) }; if (enabled && available) synchronized(LOCK) { save(load()) } }
    val available: Boolean get() = !app.isDeviceProtectedStorage && app.getSystemService(UserManager::class.java)?.isUserUnlocked != false

    fun enable() { prefs.edit { putBoolean("enabled", true) } }
    /** Off is also a delete: the file and its key go. */
    fun disable() = synchronized(LOCK) { prefs.edit { putBoolean("enabled", false) }; sealed.delete() }

    /** Newest first, pruned to the retention window. Blocking: call off the main thread. */
    fun entries(): List<NotesSessionEntry> = if (!enabled || !available) emptyList() else synchronized(LOCK) {
        val stored = read(); val kept = prune(stored)
        if (kept.size != stored.size) save(kept)
        kept.sortedByDescending { it.time }
    }

    /** Keeps [document] under its session id, replacing an earlier copy of the same session. */
    fun put(id: String, title: String, document: JSONObject) {
        if (!enabled || !available) return
        val entry = NotesSessionEntry(id, clock(), title.take(MAX_TITLE), document.optString("text").length, document)
        synchronized(LOCK) { save((load().filter { it.id != id } + entry).takeLast(MAX_ENTRIES)) }
    }

    fun delete(id: String) = synchronized(LOCK) { if (available) load().let { all -> all.filter { it.id != id }.let { if (it.size != all.size) save(it) } } }

    private fun load() = prune(read())
    private fun prune(entries: List<NotesSessionEntry>) = (clock() - retention.millis).let { cutoff -> entries.filter { it.time >= cutoff } }

    private fun read(): List<NotesSessionEntry> {
        val plain = sealed.read() ?: return emptyList()
        return try {
            val array = JSONArray(String(plain, Charsets.UTF_8))
            (0 until array.length()).map { i ->
                array.getJSONObject(i).let { NotesSessionEntry(it.getString("id"), it.getLong("time"), it.getString("title"), it.getInt("chars"), it.getJSONObject("doc")) }
            }
        } catch (_: Exception) { sealed.delete(); emptyList() } finally { plain.fill(0) }
    }

    private fun save(entries: List<NotesSessionEntry>) {
        if (entries.isEmpty()) { sealed.delete(); return }
        val array = JSONArray()
        entries.forEach { array.put(JSONObject().put("id", it.id).put("time", it.time).put("title", it.title).put("chars", it.chars).put("doc", it.document)) }
        val plain = array.toString().toByteArray(Charsets.UTF_8)
        try { sealed.write(plain) } finally { plain.fill(0) }
    }

    companion object {
        const val FILE_NAME = "notes_sessions.bin"
        const val MAX_ENTRIES = 50
        const val MAX_TITLE = 120
        private const val ALIAS = "chirp_notes_sessions_v1"
        private val LOCK = Any()
    }
}
