package dev.chirp.android

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Owns voice state, separate from HeliBoard's typing/composing state. All editor calls are main-thread. */
internal class KeyboardDictation(
    private val host: InputMethodService,
    private val captureFactory: ((ByteArray) -> Boolean, (Double) -> Unit, (String?) -> Unit) -> Capture,
    private val transportFactory: (okhttp3.OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val prepare: () -> Unit,
    private val resync: (Int, Int) -> Unit,
    private val pairing: () -> Pairing? = { SettingsStore(host).pairing() },
    private val checkHealth: Boolean = true,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store = SettingsStore(host)
    private val client = ChirpNetwork.client(host)
    private val gesture = MicGesture()
    private var strip: KeyboardStrip? = null
    private var session: DictationStream? = null
    private var warmed: ImeTransport? = null
    private var warmEvent: ((ServerEvent) -> Unit)? = null
    private var warmFailure: (() -> Unit)? = null
    private val warmExpiry = Runnable { closeWarm() }
    private fun closeWarm() {
        handler.removeCallbacks(warmExpiry)
        warmed?.close(immediate = true); warmed = null
        warmEvent = null; warmFailure = null
    }
    private fun prewarm(paired: Pairing) {
        if (active || warmed != null) return
        warmed = transportFactory(client, paired, { warmEvent?.invoke(it) }, {
            warmed = null; warmFailure?.invoke()
        }).also { it.connect() }
        handler.postDelayed(warmExpiry, 30000)
    }
    private fun takeTransport(paired: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport {
        handler.removeCallbacks(warmExpiry)
        val ready = warmed
        warmed = null
        return if (ready != null) { warmEvent = event; warmFailure = failure; ready }
        else transportFactory(client, paired, event, failure)
    }
    private var composing: ComposingSession? = null
    private val partialFrames = PartialFrames({ partial ->
        applying = true
        try { composing?.partial(partial) } finally { applying = false }
    })
    private var visible = false
    private var destroyed = false
    private var applying = false
    private var version = 0
    private var healthCall: okhttp3.Call? = null
    private var message = "Tap mic · hold to talk"
    private var text = ""
    private var undo = false
    private var notice = false
    private var targetPackage: String? = null
    private var styleOverride: String? = null
    private var currentStyle = CorrectionProfile("default", "Default")
    private var retained = false
    private var selectionStart = -1
    private var selectionEnd = -1
    private var insertionStart = -1
    private var expectedCursor = -1
    private var pressAt = 0L
    private var firstPartial: Long? = null
    private var stopAt: Long? = null
    private var finalLatency: Long? = null
    private val expiry = Runnable { forgetUndo(); notice = false; message = "Tap mic · hold to talk"; render() }
    val active get() = session != null
    val ownsComposition get() = active || applying

    fun attach(view: KeyboardStrip) {
        strip = view
        view.mic.setOnClickListener { toggle() }
        view.mic.setOnLongClickListener { if (!active) { quickOptions(); true } else false }
        view.status.setOnClickListener { action()?.let(::openAction) }
        view.cancel.setOnClickListener { cancel("Cancelled") }
        view.raw.setOnClickListener {
            val target = composing ?: return@setOnClickListener
            val previousLength = target.committedLength
            applying = true
            val changed = try { target.useRaw(expectedCursor) } finally { applying = false }
            if (changed) {
                expectedCursor += target.committedLength - previousLength
                selectionStart = expectedCursor; selectionEnd = expectedCursor
                forgetUndo(); message = "Used raw"; handler.postDelayed(expiry, 5000); resync(selectionStart, selectionEnd)
            }
            render()
        }
        render()
    }
    private fun setup(section: String = "settings") {
        host.requestHideSelf(0)
        host.startActivity(android.content.Intent(host, SetupActivity::class.java)
            .putExtra("section", section).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP or android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
    private fun action() = DictationAction.forStatus(message)
    private fun openAction(action: DictationAction) {
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> host.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", host.packageName, null)).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            DictationAction.NETWORK -> {
                val tailscale = host.packageManager.getLaunchIntentForPackage("com.tailscale.ipn")
                if (tailscale != null) host.startActivity(tailscale.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) else setup("network")
            }
        }
    }
    private fun quickOptions() {
        val anchor = strip?.mic ?: return
        android.widget.PopupMenu(anchor.context, anchor).apply {
            if (store.health.cleanupAvailable()) {
                val selected = styleOverride ?: store.style(targetPackage).id
                CleanupStyles.profiles(store.health).forEach { profile ->
                    menu.add("Style · ${profile.name}" + (if (profile.rewrites) " · rewrites" else "") +
                        if (selected == profile.id) " ✓" else "").setOnMenuItemClickListener {
                        styleOverride = profile.id; currentStyle = profile; render(); true
                    }
                }
            }
            if (store.health.cleanupAvailable()) menu.add((if (store.correction) "Clean-up on ✓" else "Clean-up off") + " · " + correctionLabel(store.health)).setOnMenuItemClickListener {
                store.correction = !store.correction; true
            }
            menu.add("Chirp settings").setOnMenuItemClickListener { setup(); true }
            show()
        }
    }
    fun touch(action: Int) {
        if (session?.stopping == true) return
        val command = when (action) {
            MotionEvent.ACTION_DOWN -> gesture.down(SystemClock.uptimeMillis(), active)
            MotionEvent.ACTION_UP -> gesture.up(SystemClock.uptimeMillis())
            MotionEvent.ACTION_CANCEL -> gesture.cancel()
            else -> MicGesture.Action.NONE
        }
        when (command) {
            MicGesture.Action.START -> start()
            MicGesture.Action.STOP -> stop()
            MicGesture.Action.CANCEL -> cancel("Cancelled")
            MicGesture.Action.NONE -> Unit
        }
    }
    fun toggle() { if (active) stop() else start() }
    fun input(info: EditorInfo?, restarting: Boolean) {
        // HeliBoard owns view recreation; a real editor restart invalidates this utterance.
        if (active || undo) cancel()
        targetPackage = info?.packageName; styleOverride = null
        selectionStart = info?.initialSelStart ?: -1
        selectionEnd = info?.initialSelEnd ?: -1
    }
    fun shown() {
        if (destroyed) return
        visible = true; render()
        val paired = pairing() ?: return
        prewarm(paired)
        if (!checkHealth) return
        val id = ++version
        val call = ChirpNetwork.healthCall(client, paired)
        healthCall?.cancel(); healthCall = call
        scope.launch {
            try {
                val health = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
                if (!visible || destroyed || version != id) return@launch
                healthCall = null
                if (!health.correctionAvailable || correctionLabel(store.health) != correctionLabel(health) ||
                    health.correctionLeavesMachine && health.correctionHost == null) store.correction = false
                store.health = health; retained = health.debugRetention; render()
            } catch (_: Exception) { if (version == id) healthCall = null }
        }
    }
    private fun start() {
        if (!visible || destroyed || active) return
        if (ContextCompat.checkSelfPermission(host, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            showNotice("Allow microphone in Chirp setup"); return
        }
        val info = host.currentInputEditorInfo ?: return
        val type = info.inputType and InputType.TYPE_MASK_CLASS
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        if ((type == InputType.TYPE_CLASS_TEXT && variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) ||
            (type == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)) {
            showNotice("Dictation unavailable in password fields"); return
        }
        val paired = pairing() ?: run { showNotice("Pair your Mac in Chirp setup"); return }
        val connection = host.currentInputConnection ?: return
        forgetUndo(); notice = false; prepare()
        currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == styleOverride } ?: store.style(targetPackage)
        insertionStart = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: minOf(info.initialSelStart, info.initialSelEnd)
        expectedCursor = insertionStart
        composing = ComposingSession(connection, insertionStart) { value ->
            android.text.SpannableString(value).apply {
                setSpan(android.text.style.UnderlineSpan(), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                val ink = VoicePalette.of(host).ink and 0x00ffffff or 0xbb000000.toInt()
                setSpan(android.text.style.ForegroundColorSpan(ink), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        text = ""; pressAt = SystemClock.elapsedRealtime(); firstPartial = null; stopAt = null; finalLatency = null
        val stream = DictationStream(
            transportFactory = { event, failed -> takeTransport(paired, event, failed) },
            captureFactory = captureFactory,
            changed = { status, partial ->
                message = status
                if (partial != null) {
                    if (firstPartial == null) firstPartial = SystemClock.elapsedRealtime() - pressAt
                    text = partial.text
                    partialFrames.offer(partial)
                }
                render()
            },
            level = { strip?.level(it) },
            retention = {
                ++version // a late health response must not overwrite Ready's retention flag
                retained = it; store.health = store.health?.copy(debugRetention = it); render()
            },
            final = { result ->
                partialFrames.clear()
                applying = true
                val inserted = try { composing?.final(result) == true } finally { applying = false }
                if (inserted) {
                    expectedCursor = insertionStart + (composing?.committedLength ?: 0)
                    selectionStart = expectedCursor; selectionEnd = expectedCursor
                }
                notice = inserted
                if (inserted) haptic()
                message = if (!inserted) "Text field unavailable — try again"
                    else if (result.correctionError != null) "kept original"
                    else if (result.corrected) "cleaned"
                    else "Inserted · tap mic to dictate again"
                text = ""; finalLatency = stopAt?.let { SystemClock.elapsedRealtime() - it }
                undo = inserted && result.corrected && result.raw != result.text
                if (notice) handler.postDelayed(expiry, 5000)
                if (!undo) { composing?.forgetUndo(); composing = null }
            },
            correcting = { event ->
                partialFrames.clear()
                text = event.raw
                currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == event.profile } ?: currentStyle
                applying = true
                try { composing?.partial(ServerEvent.Partial(event.seq, event.raw, "")) } finally { applying = false }
            },
            ended = {
                session = null
                warmEvent = null; warmFailure = null
                if (!notice && visible) { notice = true; handler.postDelayed(expiry, 5000) }
                if (!undo) { composing?.cancel(); composing = null }
                text = ""; resync(selectionStart, selectionEnd)
                client.connectionPool.evictAll(); render()
            },
        )
        session = stream
        stream.start(store.correction && store.health.cleanupAvailable(), currentStyle.id,
            instructions = "", prompt = store.promptEdits[currentStyle.id])
        haptic()
    }
    private fun stop() { stopAt = SystemClock.elapsedRealtime(); session?.stop(); haptic(); render() }
    fun beforeEdit() { if (active || undo) cancel() }
    fun selection(oldStart: Int, oldEnd: Int, start: Int, end: Int, composingStart: Int, composingEnd: Int) {
        selectionStart = start; selectionEnd = end
        if (applying) return
        if (active) {
            if (composingStart >= 0 && start == composingEnd && end == composingEnd) insertionStart = composingStart
            else if (start != oldStart || end != oldEnd) cancel("Text field changed — start again")
        } else if (undo && (start != expectedCursor || end != expectedCursor)) { forgetUndo(); render() }
    }
    fun cancel(status: String = "Tap mic · hold to talk") {
        gesture.cancel(); partialFrames.clear()
        // Clear editor composition before notifying HeliBoard that it can resume typing.
        applying = true
        try { composing?.cancel() } finally { applying = false }
        composing = null; forgetUndo()
        val old = session; session = null; old?.cancel()
        notice = false; message = status; text = ""; render()
    }
    private fun forgetUndo() { handler.removeCallbacks(expiry); undo = false; composing?.forgetUndo(); if (!active) composing = null }
    fun hidden() {
        visible = false; ++version; healthCall?.cancel(); healthCall = null
        closeWarm(); cancel(); client.dispatcher.cancelAll(); client.connectionPool.evictAll()
    }
    fun destroy() {
        destroyed = true; hidden(); scope.cancel(); handler.removeCallbacksAndMessages(null)
        strip = null; ChirpNetwork.dispose(client)
    }
    private fun showNotice(value: String) {
        message = value; notice = true
        handler.removeCallbacks(expiry); handler.postDelayed(expiry, 5000); render()
    }
    private fun haptic() { if (store.haptics) strip?.mic?.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
    private fun render() {
        val status = if (store.debugOverlay) "$message · first ${firstPartial ?: "—"} ms · final ${finalLatency ?: "—"} ms" else message
        strip?.show(action()?.let { "$status · ${it.label}" } ?: status, "", active, session?.stopping == true, undo, retained || store.health?.debugRetention == true,
            polishing = session?.polishing == true, style = currentStyle.name, notice = notice)
        strip?.status?.isClickable = action() != null
        val disclosure = if (retained || store.health?.debugRetention == true) "Debug retention on. " else ""
        strip?.status?.contentDescription = disclosure + (action()?.let { "$message. ${it.label}" } ?: if (undo) "$status. Use raw available for five seconds." else status)
    }
}
