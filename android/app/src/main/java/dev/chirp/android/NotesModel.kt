package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
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
 * What the Notes screen shows, in memory only: it survives rotation and folding with the activity's view model and
 * is dropped with it (New, or leaving the screen). Nothing is written to preferences, files or logs.
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
) : ViewModel() {
    private val app = context.applicationContext as android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OkHttpClient? = null
    private var api: NotesApi? = null
    private var refreshing = 0
    private var ticker: Job? = null
    private var inForeground = false
    private var editing = false
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

    // What the screen reads.
    val state get() = revision.let { recorder.state }
    val document get() = revision.let { recorder.document }
    val structuring get() = revision.let { recorder.structuring }
    val reorganizing get() = revision.let { recorder.reorganizeStatus }
    val level get() = revision.let { recorder.level }
    val retained get() = revision.let { recorder.debugRetention } || health?.debugRetention == true
    val recording get() = state.capturing
    val busy get() = state == NotesRecorder.State.STOPPING
    val hasContent get() = !document.isEmpty
    val canUndo get() = revision.let { recorder.canUndo }
    val canOrganize get() = reorganizing !is Reorganizing.Unavailable && !reorganizing.running && !busy && document.text.isNotBlank()
    /** The switch is offered once the Mac's health says structuring exists and clean-up is on. */
    val structureAvailable get() = health?.let { it.correctionAvailable && it.notesStructure } == true
    val structureHost get() = health?.takeIf { it.correctionLeavesMachine }?.correctionHost
    var elapsed by mutableStateOf(0.0)
        private set

    val hearing get() = document.let { d -> listOf(d.unstructuredTail, d.livePartial).filter(String::isNotBlank).joinToString(" ") }

    val elapsedText get() = elapsed.toInt().let { s -> if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60) }

    val status: String get() = message ?: when (state) {
        NotesRecorder.State.IDLE -> if (paired) IDLE else "Pair your Mac in Chirp setup"
        NotesRecorder.State.STARTING -> "Connecting to Mac…"
        NotesRecorder.State.RECORDING -> organizingText ?: if (structuring == Structuring.Running) "Updating notes…" else "Listening…"
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
        message = null
        if (!micGranted()) { message = "Allow microphone in Chirp setup"; return }
        pairing().also { paired = it != null } ?: run { message = "Pair your Mac in Chirp setup"; return }
        recorder.options = options()
        recorder.configure(structureEnabled, health)
        recorder.start()
    }

    fun stop() { message = null; recorder.stop() }

    fun organize() { message = null; recorder.organize() }
    fun undo() = recorder.undoOrganize()

    /** New: an empty document (only while not recording). */
    fun clear() {
        if (state.active) return
        recorder.reset(); field = TextFieldValue(""); message = null; elapsed = 0.0
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

    /** Replays AI changes onto the editor, keeping the caret where the user left it. */
    private fun sync() {
        val changes = recorder.takePendingChanges()
        if (!editing) {
            var value = field
            for (change in changes) {
                val composition = value.composition?.takeIf { it.max <= change.start }
                value = TextFieldValue(change.applied(value.text), TextRange(change.map(value.selection.start), change.map(value.selection.end)), composition)
            }
            val text = recorder.document.text
            if (value.text != text) value = TextFieldValue(text, TextRange(value.selection.start.coerceAtMost(text.length), value.selection.end.coerceAtMost(text.length)))
            if (value != field) field = value
        }
        elapsed = recorder.elapsed
        val active = recorder.state.active
        if (active != inForeground) {
            inForeground = active; foreground(active)
            ticker?.cancel()
            ticker = if (active) scope.launch { while (isActive) { delay(1000); elapsed = recorder.elapsed; revision++ } } else null
            if (!active) client?.let(ChirpNetwork::release)
        }
        revision++
    }

    /** Copy and Share: the notes, then the transcript, as Markdown. */
    fun export() = document.exportMarkdown()

    override fun onCleared() {
        recorder.onChange = null
        recorder.dispose()
        ticker?.cancel()
        if (inForeground) { inForeground = false; foreground(false) }
        scope.cancel()
        field = TextFieldValue("")
        client?.let(ChirpNetwork::dispose); client = null; api = null
    }

    companion object { const val IDLE = "Tap Record to take notes" }
}
