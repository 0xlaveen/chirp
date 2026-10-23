package dev.chirp.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.UserManager
import android.util.AtomicFile
import java.io.File
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** One background thread for the recovery copy, so writes land in order and never on the main thread. */
internal object NotesIo {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "chirp-notes").apply { isDaemon = true } }
    fun run(work: () -> Unit) { executor.execute { try { work() } catch (_: Exception) { /* Best effort, never logged. */ } } }
}

/** One file sealed with AES-GCM under a Keystore key; anything that cannot be opened is deleted, never repaired. */
internal class SealedFile(private val file: File, private val keys: HistoryKeys, private val header: ByteArray) {
    val exists get() = file.exists()

    fun write(plain: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keys.get(create = true)) // Fresh random IV for every write.
        cipher.updateAAD(header)
        val sealed = cipher.doFinal(plain)
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(header); stream.write(cipher.iv); stream.write(sealed); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
    }

    fun read(): ByteArray? {
        if (!file.exists()) return null
        return try {
            val bytes = AtomicFile(file).readFully()
            require(bytes.size > header.size + IV_BYTES && bytes.copyOfRange(0, header.size).contentEquals(header))
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, keys.get(create = false) ?: error("missing key"), GCMParameterSpec(128, bytes, header.size, IV_BYTES))
            cipher.updateAAD(header)
            cipher.doFinal(bytes, header.size + IV_BYTES, bytes.size - header.size - IV_BYTES)
        } catch (_: Exception) { AtomicFile(file).delete(); null }
    }

    /** The file and its key: crypto-shredded. */
    fun delete() { AtomicFile(file).delete(); try { keys.delete() } catch (_: Exception) { } }

    private companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}

/**
 * The Notes recovery copy: while notes are unsaved, the session (notes, transcript, name, elapsed audio; never audio) is
 * sealed with its own Android Keystore AES-GCM key in app-private no-backup storage, so a killed process, a crash or a
 * restart loses nothing. Written at most every [INTERVAL_MS], at once after a commit, an AI change or a state change.
 * Deleted on Save, Discard and New, and with the switch. A copy that cannot be opened is deleted, never repaired.
 */
internal class NotesJournal(
    context: Context,
    private val keys: HistoryKeys = KeystoreKeys(ALIAS),
    private val store: SettingsStore = SettingsStore(context.applicationContext),
    private val io: (() -> Unit) -> Unit = NotesIo::run,
    private val clock: () -> Long = SystemClock::uptimeMillis,
) {
    private val app = context.applicationContext ?: context
    private val sealed = SealedFile(File(app.noBackupFilesDir, FILE_NAME), keys, byteArrayOf('C'.code.toByte(), 'N'.code.toByte(), 1))
    private val handler = Handler(Looper.getMainLooper())
    private var snapshot: (() -> JSONObject?)? = null
    private var last = Long.MIN_VALUE / 2
    private val flush = Runnable { write() }

    val enabled get() = store.notesRecovery
    /** Credential-encrypted storage only: nothing is written before first unlock. */
    private val available get() = app.getSystemService(UserManager::class.java)?.isUserUnlocked != false

    /** The session changed. [snapshot] is read on the main thread when the write is due; null deletes the copy. */
    fun update(snapshot: () -> JSONObject?, now: Boolean = false) {
        if (!enabled) return
        this.snapshot = snapshot
        handler.removeCallbacks(flush)
        val wait = if (now) 0L else (INTERVAL_MS - (clock() - last)).coerceAtLeast(0L)
        if (wait == 0L) write() else handler.postDelayed(flush, wait)
    }

    /** Writes what is due now (the screen is going away). */
    fun flush() { if (snapshot != null) { handler.removeCallbacks(flush); write() } }

    /** Saved, discarded or new notes, or the switch turned off: the copy and its key go. */
    fun delete() {
        handler.removeCallbacks(flush); snapshot = null
        io { synchronized(LOCK) { sealed.delete() } }
    }

    private fun write() {
        val json = snapshot?.invoke(); snapshot = null; last = clock()
        if (json == null) { delete(); return }
        if (!available) return
        val plain = json.put("v", VERSION).toString().toByteArray(Charsets.UTF_8)
        io { synchronized(LOCK) { try { sealed.write(plain) } finally { plain.fill(0) } } }
    }

    /** The copy left by a session that did not end with Save or Discard; blocking, so call it off the main thread. */
    fun read(): JSONObject? = synchronized(LOCK) {
        if (!enabled || !available) return null
        val plain = sealed.read() ?: return null
        try {
            val json = JSONObject(String(plain, Charsets.UTF_8))
            // A copy from a newer Chirp stays on disk for that version.
            if (json.optInt("v") > VERSION) null else json
        } catch (_: Exception) { sealed.delete(); null } finally { plain.fill(0) }
    }

    companion object {
        const val FILE_NAME = "notes_recovery.bin"
        const val INTERVAL_MS = 2000L
        const val VERSION = 1
        private const val ALIAS = "chirp_notes_v1"
        private val LOCK = Any()
    }
}
