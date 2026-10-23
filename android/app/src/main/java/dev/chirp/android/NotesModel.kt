package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * What the Notes screen shows: it survives rotation and folding with the activity's view model. Until the notes are
 * saved, only the sealed recovery copy ([NotesJournal], when on) outlives the process; nothing goes to preferences or logs.
 */
internal class NotesModel(
    context: Context,
    private val store: SettingsStore = SettingsStore(context.applicationContext),
    private val captureFactory: ((ByteArray, Float) -> Unit, (Double) -> Unit, (String?) -> Unit) -> Capture = { frame, level, done -> NotesCapture(frame, level, done) },
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure)
    },
    private val apiFactory: (OkHttpClient, Pairing) -> NotesApi = ::HttpNotesApi,
    private val micGranted: () -> Boolean = {
        ContextCompat.checkSelfPermission(context.applicationContext, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    },
    private val pairing: () -> Pairing? = { store.pairing() },
    private val fetchHealth: (OkHttpClient, Pairing) -> Health? = { client, paired ->
        try { ChirpNetwork.health(client, paired) } catch (_: Exception) { null }
    },
    private val tailscale: TailscaleControl = AndroidTailscale(context.applicationContext),
    /** Starts or stops the microphone foreground service; the recording itself lives here. */
    private val foreground: (Boolean) -> Unit = { on -> NotesService.set(context.applicationContext, on) },
    private val io: suspend (suspend () -> Unit) -> Unit = { withContext(Dispatchers.IO) { it() } },
    private val journal: NotesJournal? = NotesJournal(context.applicationContext, store = store),
    private val sessions: NotesSessions? = NotesSessions(context.applicationContext),
    private val timings: NotesTimingLog? = NotesTimingLog(context.applicationContext),
    /** Fire-and-forget storage work, in order, off the main thread. */
    private val background: (() -> Unit) -> Unit = NotesIo::run,
) : ViewModel(), NotesControls.Session {
    private val app = context.applicationContext as android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OkHttpClient? = null
    private var api: NotesApi? = null
    private var refreshing = 0
    private var ticker: Job? = null
    private var inForeground = false
    private var editing = false
    private var published: NotesRecorder.State? = null
    private var committedCount = 0
    private var pendingSeen = 0
    private var visible = true
    private var counter: NotesSessionCounter? = null
    /** What was last kept in "Recent notes", so an unchanged session is not written again. */
    private var keptKey: List<Any?>? = null
    /** What was last saved to a file; the notes are unsaved ([dirty]) once anything differs. */
    private var savedKey: List<Any?>? = null
    private var health by mutableStateOf(store.health)
    /** Bumped on every recorder change, so Compose reads the recorder's plain fields afresh. */
    private var revision by mutableIntStateOf(0)

    var field by mutableStateOf(TextFieldValue(""))
        private set
    var focused = false
        set(value) { field = value; reportFocus() }
    var message by mutableStateOf<String?>(null)
    var raw by mutableStateOf(false)
    var paired by mutableStateOf(pairing() != null)
        private set
    /** "Structure notes": on by default only while structuring stays on the Mac (text never leaves it). */
    var structureEnabled by mutableStateOf(health?.correctionLeavesMachine != true)
        private set
    /** "Recovered unsaved notes from 14:03 · 52 min", until the user saves, discards or records. */
    var recovered by mutableStateOf<String?>(null)
        private set
    /** Kept sessions for the "Recent notes" sheet, newest first; loaded on demand. */
    var recent by mutableStateOf<List<NotesSessionEntry>>(emptyList())
        private set
    /** Battery saver: the screen is off (or Notes is out of sight), so editor updates, the ticker and the meter wait. */
    override var quiet = false
        private set

    private fun http() = client ?: ChirpNetwork.client(app).also { client = it }

    val recorder = NotesRecorder(
        transportFactory = { event, failed -> transportFactory(http(), requireNotNull(pairing()), event, failed) },
        captureFactory = captureFactory,
        structure = { request -> call { it.structure(request) } },
        reorganize = { request -> call { it.reorganize(request) } },
        options = options(), health = health, structuringEnabled = structureEnabled,
    ).also { it.onChange = ::sync }

    private suspend fun <T> call(body: (NotesApi) -> T): T {
        val current = api ?: apiFactory(http(), requireNotNull(pairing())).also { api = it }
        var result: Result<T>? = null
        io { result = runCatching { body(current) } }
        return requireNotNull(result).getOrThrow()
    }

    /** Clean-up with the hidden `live_notes` style when the Mac has it, else the default style and its edited prompt. */
    private fun options() = NotesRecorder.Options(store.correction && health.cleanupAvailable(),
        if (health?.notesCorrection == true) "live_notes" else "default",
        if (health?.notesCorrection == true) null else store.promptEdits["default"])

    /** A session that ended without Save or Discard (process killed, crash, restart) comes back stopped and unsaved. */
    private fun recover(journal: NotesJournal) = scope.launch {
        var json: org.json.JSONObject? = null
        io { json = journal.read() }
        val copy = json ?: return@launch
        if (recorder.state.active || !recorder.document.isEmpty) return@launch
        val restored = try { NotesDocument.fromJson(copy) } catch (_: Exception) { journal.delete(); return@launch }
        val seconds = copy.optDouble("elapsed", 0.0)
        recorder.restore(restored, seconds)
        if (restored.isEmpty) { journal.delete(); return@launch }
        recovered = "Recovered unsaved notes from " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(restored.startedAt)) +
            " · " + (seconds / 60).toInt().coerceAtLeast(1) + " min"
    }

    // What the screen reads.
    override val state get() = revision.let { recorder.state }
    val document get() = revision.let { recorder.document }
    val structuring get() = revision.let { recorder.structuring }
    val reorganizing get() = revision.let { recorder.reorganizeStatus }
    val level get() = revision.let { recorder.level }
    val retained get() = revision.let { recorder.debugRetention } || health?.debugRetention == true
    val recording get() = state.capturing
    val busy get() = state == NotesRecorder.State.STOPPING
    val paused get() = state == NotesRecorder.State.PAUSED
    val hasContent get() = !document.isEmpty
    private fun key() = recorder.document.let { listOf(it.id, it.version, it.segments.size, it.name) }
    /** Content that no Save has written as it is now: leaving or New asks first, and the recovery copy keeps it. */
    val dirty get() = revision.let { hasContent && savedKey != key() }
    val title get() = document.title().removePrefix("# ")
    val recoveryOn get() = journal?.enabled == true
    /** "Keep notes on this phone": stopped notes are kept in Recent notes, so leaving or New need not ask. */
    val keeps get() = sessions?.enabled == true
    val canUndo get() = revision.let { recorder.canUndo }
    val canOrganize get() = reorganizing !is Reorganizing.Unavailable && !reorganizing.running && !busy && document.text.isNotBlank()
    /** The switch is offered once the Mac's health says structuring exists and clean-up is on. */
    val structureAvailable get() = health?.let { it.correctionAvailable && it.notesStructure } == true
    val structureHost get() = health?.takeIf { it.correctionLeavesMachine }?.correctionHost
    var elapsed by mutableStateOf(0.0)
        private set
    override val recordedSeconds get() = recorder.elapsed

    val hearing get() = document.let { d -> listOf(d.unstructuredTail, d.livePartial).filter(String::isNotBlank).joinToString(" ") }

    val elapsedText get() = elapsed.toInt().let { s -> if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60) }

    val status: String get() = message ?: when (state) {
        NotesRecorder.State.IDLE -> if (paired) IDLE else "Pair your Mac in Chirp setup"
        NotesRecorder.State.STARTING -> "Connecting to Mac…"
        NotesRecorder.State.RECORDING -> organizingText ?: if (structuring == Structuring.Running) "Updating notes…" else "Listening…"
        NotesRecorder.State.PAUSED -> recorder.error?.let { "Couldn’t resume: $it" } ?: organizingText ?: "Paused"
        NotesRecorder.State.STOPPING -> (organizingText ?: "Finishing…") + (revision.let { recorder.stoppingElapsed }?.takeIf { it >= 3000 }?.let { " · ${it / 1000} s" } ?: "")
        NotesRecorder.State.STOPPED -> organizingText ?: "Stopped · Record adds to these notes"
        NotesRecorder.State.ERROR -> recorder.error?.let { error ->
            // A failed connection to a tailnet Mac usually means Tailscale is off; say that instead.
            if (error.startsWith("Mac unreachable")) pairing()?.let(::tailscaleStatus) ?: error else error
        } ?: "Notes stopped"
    }

    private val organizingText get() = when (val r = reorganizing) {
        is Reorganizing.Organizing -> "Organizing notes… ${r.step}/${r.of}"
        Reorganizing.Running -> "Organizing notes…"
        else -> null
    }

    /** Why the notes are a plain editor and live transcript, or null when structuring runs. */
    val explanation: String? get() = when ((structuring as? Structuring.Off)?.why) {
        StructuringOff.CORRECTION_OFF -> "Clean-up is off on your Mac, so these notes are a plain editor beside the live transcript."
        StructuringOff.UNSUPPORTED -> "Chirp on your Mac is too old to structure notes — update it. The transcript still works."
        StructuringOff.WAITING -> if (paired) "Checking your Mac…" else null
        else -> null
    }

    val organizeNote: String? get() = when (val r = reorganizing) {
        is Reorganizing.Failed -> "Couldn’t organize (${r.label}) — will retry"
        is Reorganizing.Organized -> if (r.failed == 0) "Organized" else "Organized · ${r.failed} kept as they were" + (r.reason?.let { " ($it)" } ?: "")
        Reorganizing.Conflict -> "Notes changed while organizing — try again"
        Reorganizing.TooLong -> "Too long to organize — split the last section with a heading"
        else -> (structuring as? Structuring.Failed)?.let { "Couldn’t update notes (${it.label}) — retrying with the next segment" }
    }

    private fun tailscaleStatus(paired: Pairing): String? = when {
        !TailscaleControl.routes(paired.base) -> null
        !tailscale.installed() -> DictationAction.TAILSCALE_MISSING
        !tailscale.connected() -> DictationAction.TAILSCALE_OFF
        else -> null
    }

    /** Refreshes the Mac's health (what structuring may do). Called when the screen comes to the front. */
    fun refresh() {
        val paired = pairing().also { this.paired = it != null } ?: return
        val id = ++refreshing
        scope.launch {
            val latest = withContext(Dispatchers.IO) { fetchHealth(http(), paired) } ?: return@launch
            if (id != refreshing) return@launch
            val first = health == null
            store.health = latest; health = latest
            if (first) structureEnabled = !latest.correctionLeavesMachine
            recorder.configure(structureEnabled, latest)
            if (!recorder.state.active) recorder.options = options()
        }
    }

    fun setStructure(on: Boolean) { structureEnabled = on; recorder.configure(on, health) }
    fun setAuto(on: Boolean) = recorder.setAuto(on)
    val auto get() = revision.let { recorder.autoReorganize }

    fun toggle() { if (state.active) stop() else start() }

    fun start() {
        if (state.active) return
        message = null; recovered = null
        if (!micGranted()) { message = "Allow microphone in Chirp setup"; return }
        pairing().also { paired = it != null } ?: run { message = "Pair your Mac in Chirp setup"; return }
        recorder.options = options()
        recorder.configure(structureEnabled, health)
        recorder.start()
    }

    override fun stop() { message = null; recorder.stop() }
    override fun pause() { message = null; recorder.pause() }
    override fun resume() { message = null; recorder.resume() }
    fun togglePause() { if (paused) resume() else pause() }

    /** Rename: the title of the notes, the export and the saved file; blank goes back to the start time. */
    fun rename(name: String) {
        recorder.document.name = name.trim().take(MAX_NAME).ifEmpty { null }
        sync(); keep(now = true)
    }

    /** Save: the export goes through [open] off the main thread; the notes count as saved unless they changed meanwhile. */
    fun save(open: () -> java.io.OutputStream?) {
        val text = export(); val what = key()
        scope.launch {
            var ok = false
            io { ok = try { open()?.use { it.write(text.toByteArray(Charsets.UTF_8)) } != null } catch (_: Exception) { false } }
            if (!ok) { message = "Couldn’t save — try another place, or Share"; return@launch }
            savedKey = what; recovered = null; message = "Saved"
            if (!dirty) journal?.delete()
            revision++
        }
    }

    /** With "Keep notes on this phone": the session is kept (replacing its earlier copy) and counts as saved. */
    fun keepSession(): Boolean {
        val kept = sessions?.takeIf { it.enabled } ?: return false
        if (recorder.state.active || !hasContent) return false
        val what = key()
        if (keptKey != what) {
            val document = recorder.document
            val json = document.toJson().put("elapsed", recorder.elapsed); val title = document.title().removePrefix("# ")
            background { kept.put(document.uid, title, json) }
            keptKey = what
        }
        savedKey = what; recovered = null
        journal?.delete()
        revision++
        return true
    }

    fun loadRecent() { val kept = sessions ?: return; scope.launch { var list = emptyList<NotesSessionEntry>(); io { list = kept.entries() }; recent = list } }

    /** Opens a kept session in place of the current notes (kept first when that is on). */
    fun open(entry: NotesSessionEntry) {
        if (state.active) return
        keepSession()
        val document = try { NotesDocument.fromJson(entry.document) } catch (_: Exception) { message = "Couldn’t open these notes"; return }
        recorder.restore(document, entry.document.optDouble("elapsed", 0.0))
        message = null; recovered = null
        savedKey = key(); keptKey = savedKey
        journal?.delete()
        revision++
    }

    fun deleteKept(entry: NotesSessionEntry) {
        val kept = sessions ?: return
        recent = recent.filter { it.id != entry.id }
        if (entry.id == recorder.document.uid) keptKey = null
        background { kept.delete(entry.id) }
    }

    /** The screen came into or went out of sight (the activity's start and stop). */
    fun visible(on: Boolean) { visible = on; updateQuiet() }

    private fun updateQuiet() {
        val now = !visible && store.notesBatterySaver
        if (now == quiet) return
        quiet = now; recorder.quiet = now; counter?.quiet(now)
        // Out of sight: nothing more to do. Back: the editor, partial line and clock catch up at once.
        if (!now) sync()
        retick()
        if (recorder.state.active) NotesControls.publish(app, this)
    }

    private fun retick() {
        ticker?.cancel()
        ticker = if (inForeground && !quiet) scope.launch { while (isActive) { delay(1000); elapsed = recorder.elapsed; revision++ } } else null
    }

    fun organize() { message = null; recorder.organize() }
    fun undo() = recorder.undoOrganize()

    /** New: an empty document (only while not recording). */
    fun clear() {
        if (state.active) return
        recorder.reset(); field = TextFieldValue(""); message = null; elapsed = 0.0; recovered = null; savedKey = null; keptKey = null
        journal?.delete()
    }

    /** The editor's new value: the text change goes to the document as the user's edit. */
    fun edit(value: TextFieldValue) {
        val old = recorder.document.text
        editing = true
        try { NotesDocument.diff(old, value.text, NotesChange.Kind.USER)?.let { recorder.userEdit(it.start, it.end, it.replacement) } }
        finally { editing = false }
        field = value
        reportFocus()
    }

    private fun reportFocus() = recorder.editorFocus(
        inTail = focused && recorder.document.touchesTail(field.selection.min, field.selection.max), composing = field.composition != null)

    /**
     * Replays AI changes onto the editor, keeping the caret where the user left it. With the battery saver on and the
     * screen off, only the work that matters off screen runs (state, notification, recovery copy, service); the editor
     * and the clock catch up when the screen is back.
     */
    private fun sync() {
        val quiet = quiet
        val changes = if (quiet) emptyList() else recorder.takePendingChanges()
        counter?.let { if (quiet) it.skipped++ else it.updates++ }
        if (!quiet && !editing) {
            var value = field
            for (change in changes) {
                val composition = value.composition?.takeIf { it.max <= change.start }
                value = TextFieldValue(change.applied(value.text), TextRange(change.map(value.selection.start), change.map(value.selection.end)), composition)
            }
            val text = recorder.document.text
            if (value.text != text) value = TextFieldValue(text, TextRange(value.selection.start.coerceAtMost(text.length), value.selection.end.coerceAtMost(text.length)))
            if (value != field) field = value
        }
        if (!quiet) elapsed = recorder.elapsed
        val state = recorder.state
        val commits = recorder.document.segments.size
        val stateChanged = state != published
        if (stateChanged) { published = state; NotesControls.publish(app, this) }
        val aiChanged = if (quiet) recorder.pendingCount != pendingSeen else changes.isNotEmpty()
        pendingSeen = recorder.pendingCount
        // At once after a commit, an AI change or a state change; otherwise at most every 2 s.
        keep(now = aiChanged || commits != committedCount || stateChanged)
        committedCount = commits
        val active = state.active
        if (active != inForeground) {
            inForeground = active; foreground(active)
            if (active) counter = NotesSessionCounter(SystemClock::uptimeMillis, recorder, store.notesBatterySaver).also { it.quiet(quiet) }
            else { counter?.let { c -> timings?.let { log -> val t = c.finish(System.currentTimeMillis()); background { log.record(t) } } }; counter = null }
            retick()
            if (!active) client?.let(ChirpNetwork::release)
        }
        if (stateChanged && state == NotesRecorder.State.STOPPED) keepSession()
        if (!quiet) revision++
    }

    /** The recovery copy follows the notes while they are unsaved, and goes once they are saved or empty. */
    private fun keep(now: Boolean) = journal?.update({ if (dirty) recorder.document.toJson().put("elapsed", recorder.elapsed) else null }, now)

    /** Copy and Share: the notes, then the transcript, as Markdown. */
    fun export() = document.exportMarkdown()

    override fun onCleared() {
        // Swiped away from Recents is not a discard: the recovery copy (or the kept session) stays for next time.
        keepSession()
        journal?.flush()
        NotesControls.release(app, this)
        recorder.onChange = null
        recorder.dispose()
        ticker?.cancel()
        if (inForeground) { inForeground = false; foreground(false) }
        scope.cancel()
        field = TextFieldValue("")
        client?.let(ChirpNetwork::dispose); client = null; api = null
    }

    init { journal?.let(::recover) }

    companion object {
        const val IDLE = "Tap Record to take notes"
        const val MAX_NAME = 120
    }
}
