package dev.chirp.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@SuppressLint("SetTextI18n")
class ChirpImeService : InputMethodService() {
    private enum class Phase { IDLE, CONNECTING, RECORDING, FINALIZING }
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store by lazy { SettingsStore(this) }
    private val client by lazy { ChirpNetwork.client() }
    private val gesture = MicGesture()
    private var phase = Phase.IDLE
    private var visible = false
    private var reconfiguring = false
    @Volatile private var generation = 0
    @Volatile private var transport: StreamTransport? = null
    private var pendingHealth: okhttp3.Call? = null
    private var capture: PcmCapture? = null
    private var composing: ComposingSession? = null
    private var status = "Tap to dictate · hold to talk"
    private var partial = ""
    private var retained = false
    private var rtt: Long? = null
    private var stopAt: Long? = null
    private var finalLatency: Long? = null
    private var undo = false
    private var expectedCursor = -1
    private var selectionStart = -1
    private var selectionEnd = -1
    private var lastSequence = -1L
    private var composingStart = -1
    private var expiry: Runnable? = null
    private var deadline: Runnable? = null
    private lateinit var strip: TextView
    private lateinit var debug: TextView
    private lateinit var banner: TextView
    private lateinit var mic: Button
    private lateinit var raw: Button
    private lateinit var correction: CheckBox

    override fun onEvaluateFullscreenMode() = false

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreateInputView(): View {
        val column = column()
        banner = label("").also { column.addView(it) }
        strip = label("", 17f).apply { maxLines = 3; minHeight = dp(48) }.also { column.addView(it) }
        mic = column.button("Microphone") { }
        mic.contentDescription = "Microphone: tap to toggle, hold to talk"
        mic.minHeight = dp(80)
        mic.setOnTouchListener { view, event ->
            if (phase == Phase.FINALIZING) return@setOnTouchListener true
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> act(gesture.down(SystemClock.uptimeMillis(), phase != Phase.IDLE))
                MotionEvent.ACTION_UP -> { view.performClick(); act(gesture.up(SystemClock.uptimeMillis())) }
                MotionEvent.ACTION_CANCEL -> act(gesture.cancel())
            }
            true
        }
        correction = CheckBox(this).apply {
            setOnCheckedChangeListener { _, checked -> store.correction = checked }
        }.also { column.addView(it) }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun key(label: String, description: String, action: () -> Unit) {
            row.addView(Button(this).apply {
                text = label; contentDescription = description; minWidth = 0; minimumWidth = 0
                setPadding(0, 0, 0, 0)
                setOnClickListener { action() }
            }, LinearLayout.LayoutParams(0, dp(48), 1f))
        }
        key("✕", "Cancel dictation") { cancelSession("Cancelled") }
        key("⌫", "Backspace") { edit { currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0) } }
        key("Space", "Insert space") { edit { currentInputConnection?.commitText(" ", 1) } }
        key("↵", "Enter or editor action") { edit { enter() } }
        key("⌨ back", "Previous keyboard") { cancelSession(); previousKeyboard() }
        column.addView(row)
        raw = column.button("Use raw") { if (composing?.useRaw() == true) previousKeyboard(); forgetUndo(); render() }
        column.button("Chirp setup") {
            cancelSession()
            startActivity(Intent(this, SetupActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        debug = label("", 12f).also { column.addView(it) }
        render()
        return column
    }
    private fun act(action: MicGesture.Action) {
        when (action) {
            MicGesture.Action.START -> startSession()
            MicGesture.Action.STOP -> stopSession()
            MicGesture.Action.CANCEL -> cancelSession("Cancelled")
            MicGesture.Action.NONE -> Unit
        }
    }
    private fun startSession() {
        if (!visible || phase != Phase.IDLE) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            status = "Grant microphone permission in Chirp setup"; render(); return
        }
        val info = currentInputEditorInfo ?: return
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        if (variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) ||
            (info.inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)) {
            status = "Dictation unavailable in password fields"; render(); return
        }
        val connection = currentInputConnection ?: run { status = "Select a text field first"; render(); return }
        val pairing = store.pairing() ?: run { status = "Pair with your Mac in Chirp setup"; render(); return }
        forgetUndo()
        val id = ++generation
        composing = ComposingSession(connection)
        expectedCursor = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: minOf(info.initialSelStart, info.initialSelEnd)
        composingStart = -1
        lastSequence = -1
        phase = Phase.CONNECTING
        status = "Connecting to Mac…"; partial = ""; stopAt = null; finalLatency = null
        render()
        setDeadline(id, 18000, "Mac unreachable — is Tailscale on?")
        val healthCall = ChirpNetwork.healthCall(client, pairing)
        pendingHealth = healthCall
        scope.launch {
            try {
                val started = SystemClock.elapsedRealtime()
                val health = withContext(Dispatchers.IO) { ChirpNetwork.health(healthCall) }
                if (generation != id || !visible) return@launch
                pendingHealth = null
                rtt = SystemClock.elapsedRealtime() - started
                store.health = health; retained = health.debugRetention
                if (!health.ready) { cancelSession("Mac speech model is loading — try again shortly"); return@launch }
                // Do not enable an external destination until its host has been shown to the user.
                val oldLabel = correction.text.toString()
                if (!health.correctionAvailable || oldLabel != correctionLabel(health) ||
                    (health.correctionLeavesMachine && health.correctionHost == null)) store.correction = false
                render()
                transport = StreamTransport(client, pairing, store.correction,
                    dispatch = { callback -> handler.post { callback() } },
                    event = { event -> if (generation == id) onServerEvent(id, event) },
                    failure = { if (generation == id) cancelSession("Mac unreachable — is Tailscale on?") })
                    .also { it.connect() }
            } catch (_: Exception) {
                if (generation == id) cancelSession("Mac unreachable or pairing refused — check Tailscale and Chirp setup")
            }
        }
    }
    private fun onServerEvent(id: Int, event: ServerEvent) {
        when (event) {
            is ServerEvent.Ready -> {
                if (phase != Phase.CONNECTING) { cancelSession("Unexpected server response"); return }
                retained = event.debugRetention
                store.health = store.health?.copy(debugRetention = retained)
                clearDeadline()
                phase = Phase.RECORDING; status = "Listening…"; haptic()
                capture = PcmCapture(
                    frame = { bytes -> generation == id && transport?.audio(bytes) == true },
                    level = { value -> if (store.debugOverlay) handler.post {
                        if (generation == id) { status = "Listening · level ${(value * 100).toInt()}%"; render() }
                    } },
                    done = { error -> handler.post {
                        if (generation == id) {
                            capture = null
                            if (error != null) cancelSession(error) else finishAudio(id)
                        }
                    } })
                capture?.start()
            }
            is ServerEvent.Partial -> {
                if (phase !in setOf(Phase.RECORDING, Phase.FINALIZING) || event.seq <= lastSequence) return
                lastSequence = event.seq
                partial = event.text
                if (composing?.partial(event) != true) cancelSession("Text field unavailable — try again")
            }
            is ServerEvent.Final -> {
                if (phase != Phase.FINALIZING) { cancelSession("Unexpected server response"); return }
                clearDeadline()
                capture?.stop(); capture = null
                transport?.close(); transport = null
                phase = Phase.IDLE
                // Track expected cursor before commit triggers the editor's selection update.
                expectedCursor = (if (composingStart >= 0) composingStart else expectedCursor) + event.text.length
                if (composing?.final(event) != true) { cancelSession("Text field unavailable — try again"); return }
                finalLatency = stopAt?.let { SystemClock.elapsedRealtime() - it }
                status = "Inserted"; partial = ""
                undo = event.corrected && event.raw != event.text
                if (undo) {
                    expiry = Runnable { forgetUndo(); render(); if (visible) previousKeyboard() }
                        .also { handler.postDelayed(it, 5000) }
                } else { composing = null; previousKeyboard() }
            }
            is ServerEvent.Failure -> cancelSession(when (event.code) {
                "auth" -> "Pairing refused — pair again in Chirp setup"
                "busy" -> "Mac is busy — try again"
                "too_long" -> "Dictation limit is 120 seconds"
                "bad_audio" -> "No audio received — try again"
                else -> "Mac speech engine unavailable — try again"
            })
            ServerEvent.Unknown -> Unit
        }
        render()
    }
    private fun stopSession() {
        if (phase == Phase.CONNECTING) { cancelSession("Cancelled before microphone opened"); return }
        if (phase != Phase.RECORDING) return
        phase = Phase.FINALIZING; status = "Finishing…"; stopAt = SystemClock.elapsedRealtime()
        haptic(); capture?.stop(); render()
        // stop is sent by capture's completion callback, after its last frame and recorder.release().
    }
    private fun finishAudio(id: Int) {
        if (phase == Phase.RECORDING) {
            phase = Phase.FINALIZING; stopAt = SystemClock.elapsedRealtime(); status = "Finishing…"
        }
        if (transport?.stop() != true) { cancelSession("Mac unreachable — is Tailscale on?"); return }
        setDeadline(id, 60000, "Mac took too long to finish — try again")
        render()
    }
    private fun cancelSession(message: String = "Tap to dictate · hold to talk") {
        ++generation
        clearDeadline(); forgetUndo()
        pendingHealth?.cancel(); pendingHealth = null
        capture?.stop(); capture = null
        transport?.close(true); transport = null
        composing?.cancel(); composing = null
        partial = ""; phase = Phase.IDLE; status = message
        render()
    }
    private fun setDeadline(id: Int, ms: Long, message: String) {
        clearDeadline()
        deadline = Runnable { if (generation == id) cancelSession(message) }.also { handler.postDelayed(it, ms) }
    }
    private fun clearDeadline() { deadline?.let(handler::removeCallbacks); deadline = null }
    private fun forgetUndo() {
        expiry?.let(handler::removeCallbacks); expiry = null; undo = false; composing?.forgetUndo()
    }
    private fun haptic() { if (store.haptics && ::mic.isInitialized) mic.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
    private fun edit(action: () -> Unit) { cancelSession(); action() }
    private fun enter() {
        val info = currentInputEditorInfo ?: return
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        if (info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0 && action != EditorInfo.IME_ACTION_NONE &&
            action != EditorInfo.IME_ACTION_UNSPECIFIED) currentInputConnection?.performEditorAction(action)
        else {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
    }
    private fun previousKeyboard() {
        if (!switchToPreviousInputMethod()) getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }
    private fun render() {
        if (!::strip.isInitialized) return
        strip.text = partial.ifEmpty { status }
        banner.retention(retained || store.health?.debugRetention == true)
        mic.text = when (phase) { Phase.IDLE -> "● Tap to dictate"; Phase.CONNECTING -> "Connecting…"; Phase.RECORDING -> "■ Stop"; Phase.FINALIZING -> "Finishing…" }
        correction.text = correctionLabel(store.health)
        correction.isEnabled = phase == Phase.IDLE && store.health?.let {
            it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null)
        } == true
        correction.isChecked = store.correction
        raw.visibility = if (undo) View.VISIBLE else View.GONE
        debug.visibility = if (store.debugOverlay) View.VISIBLE else View.GONE
        debug.text = "Health RTT: ${rtt ?: "—"} ms · stop→commit: ${finalLatency ?: "—"} ms"
    }
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (!reconfiguring) {
            cancelSession()
            selectionStart = attribute?.initialSelStart ?: -1
            selectionEnd = attribute?.initialSelEnd ?: -1
        }
    }
    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting); visible = true; render()
    }
    override fun onFinishInputView(finishingInput: Boolean) {
        if (!reconfiguring) { visible = false; cancelSession() }
        if (!reconfiguring) super.onFinishInputView(finishingInput)
    }
    override fun onWindowHidden() {
        if (!reconfiguring) { visible = false; cancelSession() }
        super.onWindowHidden()
    }
    override fun onFinishInput() { if (!reconfiguring) { cancelSession(); super.onFinishInput() } }
    override fun onUnbindInput() { cancelSession(); super.onUnbindInput() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        // The service and capture survive resizing/folding; framework recreates only the view.
        reconfiguring = true
        try { super.onConfigurationChanged(newConfig) } finally { reconfiguring = false }
        render()
    }
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        selectionStart = newSelStart; selectionEnd = newSelEnd
        if (phase != Phase.IDLE) {
            if (candidatesStart >= 0 && newSelStart == candidatesEnd && newSelEnd == candidatesEnd) {
                composingStart = candidatesStart
            } else if (newSelStart != oldSelStart || newSelEnd != oldSelEnd) cancelSession("Text field changed — start again")
        } else if (undo && (newSelStart != expectedCursor || newSelEnd != expectedCursor)) {
            forgetUndo(); render()
        }
    }
    override fun onDestroy() {
        cancelSession(); scope.cancel(); handler.removeCallbacksAndMessages(null)
        ChirpNetwork.dispose(client); super.onDestroy()
    }
}
