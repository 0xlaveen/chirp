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
    private val captureFactory: ((ByteArray, Float) -> Unit, (Double) -> Unit, (String?) -> Unit) -> Capture = { frame, level, done -> NotesCapture(frame, level, done, notesInputForBuild(context.applicationContext)) },
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure,
            maxQueued = NotesRecorder.MAX_QUEUED_BYTES)
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
    /** Audio encoding, off the main thread and apart from [background] so a long encode never delays a text save. */
    private val audioWork: (() -> Unit) -> Unit = NotesAudioIo::run,
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
    private var publishedCommand = false
    private var committedCount = 0
    private var pendingSeen = 0
    private var visible = true
    private var counter: NotesSessionCounter? = null
    /** What was last written to the library, so an unchanged note is not written again. */
    private var keptKey: List<Any?>? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var saveScheduled = false
    private val saveRunnable = Runnable { saveScheduled = false; autosave(now = true) }
    /** Bumped by every open, so a load that finishes after another one started (or after New) is dropped. */
    private var openRequest = 0
    /** Restoring a document is not an edit: recorder callbacks must not resave it or change its list position. */
    private var loading = false
    /** "Stop current and continue here": the note to continue once the recording that was stopped has ended. */
    private var continueAfterStop: String? = null
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
    /** The library's live notes for the "Recent notes" sheet, newest first; loaded on demand. */
    var recent by mutableStateOf<List<NotesIndexEntry>>(emptyList())
        private set
    /** The library, for the list-detail screens: the index flow, search, rename, trash, restore, purge and kept audio. */
    val library: NotesSessions? get() = sessions
    /** Battery saver: the screen is off (or Notes is out of sight), so editor updates, the ticker and the meter wait. */
    override var quiet = false
        private set

    private fun http() = client ?: ChirpNetwork.client(app).also { client = it }

    private val streams: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { event, failed -> transportFactory(http(), requireNotNull(pairing()), event, failed) }

    val recorder = NotesRecorder(
        transportFactory = streams,
        captureFactory = captureFactory,
        structure = { request -> call { it.structure(request) } },
        reorganize = { request -> call { it.reorganize(request) } },
        options = options(), health = health, structuringEnabled = structureEnabled,
        editNotes = { request -> call { it.edit(request) } },
    ).also { it.onChange = ::sync }

    /** Edit by voice: the Command button and the notification action. */
    private val voiceEdit = NotesVoiceEdit(recorder, streams,
        microphone = { sink, ended -> captureFactory({ bytes, _ -> sink(bytes) }, {}, ended).also { it.start() } },
        selection = { field.selection.takeIf { !it.collapsed }?.let { it.min to it.max } }, scope = scope).also { it.onChange = ::sync }
    /** A press that is still down ended its command on release; one already listening (latched) ends on the next press. */
    private var commandDown = false

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
        // A recovered session is a library note, marked Recovered; the recovery copy has done its job.
        sessions?.takeIf { it.enabled }?.let { kept ->
            background { kept.put(restored.uid, copy, recovered = true) }
            keptKey = key(); savedKey = keptKey
            journal.delete()
        }
        recovered = "Recovered unsaved notes from " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(restored.startedAt)) +
            " · " + (seconds / 60).toInt().coerceAtLeast(1) + " min"
    }

    // What the screen reads.
    override val state get() = revision.let { recorder.state }
    override val shareTitle get() = displayTitle
    override fun appendShared(text: String): Boolean {
        if (state != NotesRecorder.State.RECORDING && state != NotesRecorder.State.PAUSED) return false
        val before = document.text
        edit(TextFieldValue(before + (if (before.isBlank()) "" else "\n\n") + text))
        return true
    }
    val document get() = revision.let { recorder.document }
    val structuring get() = revision.let { recorder.structuring }
    val reorganizing get() = revision.let { recorder.reorganizeStatus }
    val level get() = revision.let { recorder.level }
    val retained get() = revision.let { recorder.debugRetention } || health?.debugRetention == true
    val recording get() = state.capturing
    val busy get() = state == NotesRecorder.State.STOPPING
    val paused get() = state == NotesRecorder.State.PAUSED
    val hasContent get() = !document.isEmpty
    private fun key() = recorder.document.let { listOf(it.id, it.version, it.segments.size, it.name, recorder.state.active) }
    /** Content that no Save has written as it is now: leaving or New asks first, and the recovery copy keeps it. */
    val dirty get() = revision.let { hasContent && savedKey != key() }
    val title get() = document.title().removePrefix("# ")
    val displayTitle get() = document.displayTitle()
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

    val status: String get() = voiceEditStatus?.let(NotesVoiceEditText::status) ?: message ?: when (state) {
        NotesRecorder.State.IDLE -> if (paired) IDLE else "Pair your Mac in Chirp settings"
        NotesRecorder.State.STARTING -> "Connecting to Mac…"
        NotesRecorder.State.RECORDING -> organizingText ?: if (structuring == Structuring.Running) "Updating notes…" else "Listening…"
        NotesRecorder.State.PAUSED -> recorder.error?.let { "Couldn’t resume: $it" } ?: organizingText ?: "Paused"
        NotesRecorder.State.STOPPING -> (organizingText ?: "Finishing…") + (revision.let { recorder.stoppingElapsed }?.takeIf { it >= 3000 }?.let { " · ${it / 1000} s" } ?: "")
        NotesRecorder.State.STOPPED -> organizingText ?: "Stopped"
        NotesRecorder.State.ERROR -> recorder.error?.let { error ->
            // A failed connection to a tailnet Mac usually means Tailscale is off; say that instead.
            if (error.startsWith("Mac unreachable")) pairing()?.let(::tailscaleStatus) ?: error else error
        } ?: "Notes stopped"
    }

    // Edit by voice.
    /** The Mac can edit notes by voice (health), so the Command button is offered. */
    val voiceEditAvailable get() = revision.let { recorder.canEdit }
    val voiceEditStatus: VoiceEditStatus? get() = revision.let { voiceEdit.status.takeIf { it.isBusy } }
    val listeningForCommand get() = revision.let { voiceEdit.status.isListening }
    val canCommand get() = revision.let { voiceEdit.status.isListening || voiceEdit.canStart }
    /** The note for the last edit that did not apply. */
    val voiceEditNote: String? get() = revision.let { (voiceEdit.status as? VoiceEditStatus.Done)?.let { NotesVoiceEditText.note(it.outcome) } }
    /** "Edited · Undo" after a voice edit applied, until the next edit, a click or [NotesVoiceEdit.CHIP_MS]. */
    val showEditedChip get() = revision.let { (voiceEdit.status as? VoiceEditStatus.Done)?.outcome == NotesEditOutcome.Applied && recorder.canUndoEdit }
    val voiceEditDone: VoiceEditStatus? get() = revision.let { voiceEdit.status.takeIf { it is VoiceEditStatus.Done } }
    fun dismissVoiceEdit() = voiceEdit.dismiss()
    fun undoVoiceEdit() { recorder.undoEdit(); voiceEdit.dismiss() }
    fun cancelCommand() = voiceEdit.cancel()
    /** The Command button went down: start a command, or (a latched one) end it. */
    fun commandPress() {
        if (voiceEdit.status.isListening) { voiceEdit.finish(); commandDown = false; return }
        message = null
        voiceEdit.start()
        commandDown = voiceEdit.status.isListening
    }
    /** The button came up after [heldMs]: a hold ends the command, a tap leaves it listening until the next press. */
    fun commandRelease(heldMs: Long) {
        val ours = commandDown; commandDown = false
        if (ours && heldMs >= NotesVoiceEdit.HOLD_MS) voiceEdit.finish()
    }
    override val commanding: Boolean? get() = revision.let { if (recorder.canEdit) voiceEdit.status.isListening else null }
    override fun command() { message = null; voiceEdit.toggle() }

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
        Reorganizing.TooShort -> "Nothing to organize yet — keep going"
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
        if (voiceEdit.holdsMicrophone) { message = "Finish the spoken edit first"; return }
        message = null; recovered = null
        if (!micGranted()) { message = "Allow microphone in Chirp settings"; return }
        pairing().also { paired = it != null } ?: run { message = "Pair your Mac in Chirp settings"; return }
        recorder.options = options()
        recorder.configure(structureEnabled, health)
        recorder.keepAudio = sessions?.let { it.enabled && it.keepAudio } == true
        // Recording into a finished note continues it: a quiet divider marks where, and the audio clock goes on.
        if (recorder.state.let { it == NotesRecorder.State.STOPPED || it == NotesRecorder.State.ERROR } && document.segments.isNotEmpty())
            recorder.document.addBoundary(recorder.elapsed, System.currentTimeMillis())
        recorder.start()
    }

    /**
     * Continue recording into the library note [id]: it opens (unless it is the open note), a capture boundary is added and
     * new segments carry on from its stored audio clock. False when another note is recording and [stopCurrent] is not
     * set (offer "Stop current and continue here"); with it, that recording stops first and this one starts after.
     */
    fun continueRecording(id: String, stopCurrent: Boolean = false): Boolean {
        if (state.active) {
            if (recorder.document.uid == id) return true
            if (!stopCurrent) return false
            continueAfterStop = id; stop()
            return true
        }
        scope.launch { if (recorder.document.uid == id || load(id)) start() }
        return true
    }

    override fun stop() { message = null; recorder.stop() }
    override fun pause() { message = null; recorder.pause() }
    override fun resume() { if (voiceEdit.holdsMicrophone) { message = "Finish the spoken edit first"; return }; message = null; recorder.resume() }
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

    /**
     * Autosave: with the library on (the default) every note keeps itself, there is no Save step. Written at once after a
     * commit, an AI change or a state change, otherwise at most every [SAVE_MS]; a blank, never-named note is not kept. The
     * recovery copy stands down once the library has the note.
     */
    private fun autosave(now: Boolean) {
        if (loading) return
        val kept = sessions?.takeIf { it.enabled } ?: return
        if (!now) { if (!saveScheduled) { saveScheduled = true; mainHandler.postDelayed(saveRunnable, SAVE_MS) }; return }
        mainHandler.removeCallbacks(saveRunnable); saveScheduled = false
        val document = recorder.document
        val what = key()
        if (document.untouched || keptKey == what) return
        val json = document.toJson().put("elapsed", recorder.elapsed)
        background { kept.put(document.uid, json) }
        keptKey = what; savedKey = what; recovered = null
        journal?.delete()
    }

    /** Keeps the open note now (leaving, New, a stop). True when the note is in the library, or was never worth keeping. */
    fun keepSession(): Boolean {
        sessions?.takeIf { it.enabled } ?: return false
        autosave(now = true)
        revision++
        return true
    }

    fun loadRecent() { val kept = sessions ?: return; scope.launch { var list = emptyList<NotesIndexEntry>(); io { list = kept.entries() }; recent = list } }

    /** Opens a library note in place of the current notes (the current one is kept first). */
    fun open(entry: NotesIndexEntry) = open(entry.id)

    fun open(id: String) {
        if (state.active) return
        scope.launch { load(id) }
    }

    /** The note's record off the main thread; false when it is gone or recording began meanwhile. Late loads are dropped. */
    private suspend fun load(id: String): Boolean {
        val kept = sessions ?: return false
        if (state.active) return false
        keepSession()
        val request = ++openRequest
        var record: NotesRecord? = null
        io { record = kept.open(id) }
        if (request != openRequest || state.active) return false
        val found = record ?: run { message = "Couldn’t open these notes"; return false }
        val document = try { NotesDocument.fromJson(found.document) } catch (_: Exception) { message = "Couldn’t open these notes"; return false }
        loading = true
        try {
            recorder.restore(document, found.document.optDouble("elapsed", 0.0))
            field = TextFieldValue(recorder.document.text)
            message = null; recovered = null; elapsed = recorder.elapsed
            savedKey = key(); keptKey = savedKey
        } finally { loading = false }
        journal?.delete()
        revision++
        return true
    }

    /** Delete: into Recently Deleted. A note that is recording cannot be deleted until it is stopped. */
    fun trash(id: String): Boolean {
        val kept = sessions ?: return false
        if (state.active && recorder.document.uid == id) return false
        recent = recent.filter { it.id != id }
        if (id == recorder.document.uid) { openRequest++; keptKey = null; if (!state.active) clear() }
        background { kept.trash(id) }
        return true
    }

    fun deleteKept(entry: NotesIndexEntry) { trash(entry.id) }

    /** Delete only this note's kept audio. The text and transcript stay. */
    fun deleteAudio() {
        val id = document.uid
        background {
            if (sessions?.deleteAudio(id) == true) mainHandler.post {
                if (document.uid == id) { recorder.document.clearClips(); revision++ }
            }
        }
    }

    /** Encodes and stores a committed segment's audio, off the main thread, after the note's own write. */
    private fun keepClip(documentId: Long, segment: Int, offset: Double, pcm: ByteArray) {
        val kept = sessions?.takeIf { it.enabled && it.keepAudio }
        val document = recorder.document
        if (kept == null || document.id != documentId) { pcm.fill(0); return }
        autosave(now = true) // The note is queued for writing before its first clip is.
        val uid = document.uid
        audioWork {
            val encoded = kept.encodeClip(pcm); pcm.fill(0)
            if (encoded != null) background {
                kept.storeClip(uid, segment, offset, pcm.size, encoded)?.let { clip ->
                    mainHandler.post { if (recorder.document.id == documentId) { recorder.document.addClip(clip); revision++ } }
                }
            }
        }
    }

    /** The screen came into or went out of sight (the activity's start and stop). */
    fun visible(on: Boolean) {
        visible = on; updateQuiet()
        // Without the recording's service Android silences a hidden app's microphone, so a command on its own microphone ends.
        if (!on && !recorder.state.active) voiceEdit.cancel()
    }

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
        try { NotesDocument.diff(old, value.text, NotesChange.Kind.USER)?.let { recorder.userEdit(it.start, it.end, it.replacement); voiceEdit.dismiss() } }
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
        val commanding = voiceEdit.status.isListening
        if (stateChanged || commanding != publishedCommand) { published = state; publishedCommand = commanding; NotesControls.publish(app, this) }
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
        if (stateChanged && !state.active) continueAfterStop?.let { id -> continueAfterStop = null; scope.launch { if (load(id)) start() } }
        if (!quiet) revision++
    }

    /** The recovery copy follows the notes while they are unsaved, and goes once they are saved or empty. */
    private fun keep(now: Boolean) {
        if (loading) return
        autosave(now)
        journal?.update({ if (dirty) recorder.document.toJson().put("elapsed", recorder.elapsed) else null }, now)
    }

    /** Copy and Share: the notes, then the transcript, as Markdown. */
    fun export() = document.exportMarkdown()

    override fun onCleared() {
        // Swiped away from Recents is not a discard: the recovery copy (or the kept session) stays for next time.
        keepSession()
        journal?.flush()
        voiceEdit.cancel()
        NotesControls.release(app, this)
        recorder.onChange = null
        recorder.dispose()
        ticker?.cancel()
        if (inForeground) { inForeground = false; foreground(false) }
        scope.cancel()
        field = TextFieldValue("")
        client?.let(ChirpNetwork::dispose); client = null; api = null
    }

    init {
        recorder.audioSink = ::keepClip
        journal?.let(::recover)
    }

    companion object {
        const val IDLE = "Tap Record to take notes"
        const val MAX_NAME = 120
        /** The library is written at most this often while notes change. */
        const val SAVE_MS = 2000L
    }
}
