package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/** Places a dictated final in an ordinary text value the way the keyboard places one in an editor. */
internal object ScratchpadText {
    private fun needsSpace(previous: Char?) = previous != null && !previous.isWhitespace() && previous != '\'' && previous != '"' &&
        Character.getType(previous) != Character.START_PUNCTUATION.toInt() &&
        Character.getType(previous) != Character.INITIAL_QUOTE_PUNCTUATION.toInt()

    fun insert(value: TextFieldValue, text: String, commands: Boolean): TextFieldValue {
        val start = value.selection.min.coerceIn(0, value.text.length); val end = value.selection.max.coerceIn(start, value.text.length)
        val before = value.text.substring(0, start); val after = value.text.substring(end)
        val shaped = FinalCasing.shape(text, FinalCasing.midSentence(before.takeLast(FinalCasing.LOOKBEHIND)), commands)
        val lead = if (shaped.isNotEmpty() && !shaped.first().isWhitespace() && needsSpace(before.lastOrNull())) " " else ""
        val trail = if (shaped.isNotEmpty() && !shaped.last().isWhitespace() && after.firstOrNull()?.isLetterOrDigit() == true) " " else ""
        val inserted = lead + shaped + trail
        return TextFieldValue(before + inserted + after, TextRange(start + inserted.length))
    }
}

/**
 * Everything the Scratchpad shows, in memory only: it survives rotation with the activity's view model and
 * is dropped with it. Nothing is written to preferences, files or logs; only an opted-in history records finals.
 */
internal class ScratchpadModel(
    context: Context,
    private val store: SettingsStore = SettingsStore(context.applicationContext),
    private val history: DictationHistory = DictationHistory(context.applicationContext),
    private val captureFactory: (Context, (ByteArray) -> Boolean, (Double) -> Unit, (String?) -> Unit) -> Capture = ::captureForBuild,
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure)
    },
    private val micGranted: () -> Boolean = {
        ContextCompat.checkSelfPermission(context.applicationContext, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    },
    private val pairing: () -> Pairing? = { store.pairing() },
    private val fetchHealth: (OkHttpClient, Pairing) -> Health? = { client, paired ->
        try { ChirpNetwork.health(client, paired) } catch (_: Exception) { null }
    },
    private val tailscale: TailscaleControl = AndroidTailscale(context.applicationContext),
    private val io: (() -> Unit) -> Unit = HistoryIo::run,
) : ViewModel() {
    private val app = context.applicationContext as android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OkHttpClient? = null
    private var session: DictationStream? = null
    private var refreshing = 0

    var field by mutableStateOf(TextFieldValue(""))
    var status by mutableStateOf(IDLE)
        internal set
    var partial by mutableStateOf("")
        private set
    var active by mutableStateOf(false)
        private set
    var stopping by mutableStateOf(false)
        private set
    var polishing by mutableStateOf(false)
        private set
    var level by mutableDoubleStateOf(0.0)
        private set
    var retained by mutableStateOf(false)
        private set
    private var health by mutableStateOf(store.health)
    private var styleId by mutableStateOf(store.defaultStyle)
    /** Clean-up on or off for this screen only; the keyboard's own setting is untouched. */
    var cleanup by mutableStateOf(store.correction)
        private set

    val profiles get() = CleanupStyles.profiles(health)
    val cleanupAvailable get() = health.cleanupAvailable()
    val style get() = profiles.firstOrNull { it.id == styleId } ?: profiles.first()
    val historyOn get() = history.enabled
    var paired by mutableStateOf(pairing() != null)
        private set
    val hasText get() = field.text.isNotBlank()

    fun choose(profile: CorrectionProfile?) {
        if (active) return
        if (profile == null) cleanup = false else { cleanup = true; styleId = profile.id }
    }

    private fun http() = client ?: ChirpNetwork.client(app).also { client = it }
    private fun sync() {
        val current = session
        active = current != null; stopping = current?.stopping == true; polishing = current?.polishing == true
    }
    private fun tailscaleStatus(paired: Pairing): String? = when {
        !TailscaleControl.routes(paired.base) -> null
        !tailscale.installed() -> DictationAction.TAILSCALE_MISSING
        !tailscale.connected() -> DictationAction.TAILSCALE_OFF
        else -> null
    }

    /** Refreshes the Mac's clean-up styles. Called when the screen comes to the front. */
    fun refresh() {
        val paired = pairing().also { this.paired = it != null } ?: return
        val id = ++refreshing
        scope.launch {
            val latest = withContext(Dispatchers.IO) { fetchHealth(http(), paired) } ?: return@launch
            if (id != refreshing) return@launch
            store.health = latest; health = latest; retained = latest.debugRetention
            if (!latest.cleanupAvailable()) cleanup = false
        }
    }

    fun toggle() { if (active) stop() else start() }
    fun stop() { session?.stop(); sync() }

    fun start() {
        if (active) return
        if (!micGranted()) { status = "Allow microphone in Chirp setup"; return }
        val paired = pairing().also { this.paired = it != null } ?: run { status = "Pair your Mac in Chirp setup"; return }
        val chosen = style
        partial = ""; level = 0.0
        val stream = DictationStream(
            transportFactory = { event, failed -> transportFactory(http(), paired, event, failed) },
            captureFactory = { frame, lvl, done -> captureFactory(app, frame, lvl, done) },
            changed = { text, event ->
                // A failed connection to a tailnet Mac usually means Tailscale is off; say that instead.
                status = if (text.startsWith("Mac unreachable")) tailscaleStatus(paired) ?: text else text
                if (event != null) partial = event.text
                sync()
            },
            level = { level = it },
            retention = { retained = it; store.health = store.health?.copy(debugRetention = it) },
            final = { result ->
                field = ScratchpadText.insert(field, result.text, store.spokenCommands)
                io { history.record(result.text, result.raw.takeIf { result.corrected }, "Scratchpad", HISTORY_EDITOR) }
                status = when {
                    result.correctionError != null -> "kept original"
                    result.corrected -> "cleaned"
                    else -> "Added · tap mic to dictate again"
                }
            },
            ended = { session = null; partial = ""; level = 0.0; sync(); client?.let(ChirpNetwork::release) },
        )
        session = stream; sync()
        stream.start(cleanup && cleanupAvailable, chosen.id, prompt = store.promptEdits[chosen.id])
    }

    fun cancel(message: String = IDLE) {
        val old = session; session = null; old?.cancel()
        partial = ""; level = 0.0; sync(); status = message
    }

    /** Leaving the screen discards a live utterance; one already being finished keeps going into the text. */
    fun pause() { if (active && !stopping) cancel() }

    fun clear() {
        if (!active) { field = TextFieldValue(""); status = IDLE }
    }

    override fun onCleared() {
        session?.cancel(); session = null
        scope.cancel()
        field = TextFieldValue(""); partial = ""
        client?.let(ChirpNetwork::dispose); client = null
    }

    companion object {
        const val IDLE = "Tap the mic to dictate"
        // Plain editor: history's own rules (opt-in, never password fields) decide whether a final is kept.
        private val HISTORY_EDITOR by lazy { EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT } }
    }
}
