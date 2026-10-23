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
    private val history: HistoryRecorder? = null,
    private val started: () -> Unit = {},
    private val tailscale: TailscaleControl = AndroidTailscale(host),
    private val healthCheck: (okhttp3.Call) -> Health = ChirpNetwork::health,
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
            warmed?.failureKind?.takeIf { it.offline }?.let(::noteReach)
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
        try { if (!moved) composing?.partial(partial) } finally { applying = false }
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
    // The caret left the utterance: stop, stop touching the editor's caret, land the final where it was spoken.
    private var moved = false
    private var pressAt = 0L
    private var firstPartial: Long? = null
    private var stopAt: Long? = null
    private var finalLatency: Long? = null
    private var historyInfo: EditorInfo? = null
    private var historyId: String? = null
    private val expiry = Runnable { forgetUndo(); notice = false; message = "Tap mic · hold to talk"; render() }
    // Tailscale is checked only for tailnet pairings, locally and without DNS. Ignoring or dismissing
    // the prompt keeps it away for this keyboard process until Tailscale is next seen connected.
    private var tailnet = false
    private var vpn = false
    private var tailscaleDismissed = false
    private var tailscaleWatch: AutoCloseable? = null
    private val tailscaleTimeout = Runnable {
        if (active || message != CONNECTING) return@Runnable
        if (tailscale.connected()) tailscaleChanged() else { notice = false; message = DictationAction.TAILSCALE_STALLED; render() }
    }
    // The last health/prewarm failure marks the Mac offline for 30 s: the mic shows it before the user speaks.
    private val offline = OfflineState()
    private var offlineDismissed = false
    private var checking = false
    private val offlineExpiry = Runnable { if (message == ConnectionFailure.OFFLINE) message = IDLE; render() }
    private var secondsLeft: Int? = null
    private var spokenLeft: Int? = null
    val active get() = session != null
    val ownsComposition get() = active || applying

    fun attach(view: KeyboardStrip) {
        strip = view
        view.mic.setOnClickListener { toggle() }
        view.mic.setOnLongClickListener { if (!active) { quickOptions(); true } else false }
        view.status.setOnClickListener { val next = action(); if (next != null) openAction(next) else if (message == ConnectionFailure.OFFLINE) start() }
        view.action.setOnClickListener { action()?.let(::openAction) }
        view.cancel.setOnClickListener {
            if (action()?.prompt == true) tailscaleDismissed = true
            if (message == ConnectionFailure.OFFLINE) offlineDismissed = true
            handler.removeCallbacks(tailscaleTimeout); cancel("Cancelled")
        }
        view.raw.setOnClickListener {
            val target = composing ?: return@setOnClickListener
            applying = true
            val changed = try { target.useRaw(selectionStart, selectionEnd) } finally { applying = false }
            if (changed) {
                selectionStart = target.selectionStart; selectionEnd = target.selectionEnd
                historyId?.let { history?.usedRaw(it) }
                forgetUndo(); message = "Used raw"; handler.postDelayed(expiry, 5000); resync(selectionStart, selectionEnd)
            }
            render()
        }
        view.revert.setOnClickListener {
            val target = composing ?: return@setOnClickListener
            applying = true
            val changed = try { target.undo(selectionStart, selectionEnd) } finally { applying = false }
            if (changed) { selectionStart = target.selectionStart; selectionEnd = target.selectionEnd; resync(selectionStart, selectionEnd) }
            forgetUndo(); showNotice(if (changed) "Dictation removed" else "Text changed — nothing to undo")
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
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            // One tap asks Tailscale to connect with consent it already holds; it cannot grant VPN consent.
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) {
                handler.removeCallbacks(expiry); handler.removeCallbacks(tailscaleTimeout)
                message = CONNECTING; notice = true; render()
                handler.postDelayed(tailscaleTimeout, 10000)
            } else if (!tailscale.open()) setup("network")
        }
    }
    private fun tailscaleStatus(): String? = when {
        !tailnet -> null
        !tailscale.installed() -> DictationAction.TAILSCALE_MISSING
        !tailscale.connected() -> DictationAction.TAILSCALE_OFF
        else -> null
    }
    private fun tailscaleMessage() = action()?.prompt == true || message == CONNECTING
    private fun promptTailscale() {
        if (active || undo || notice || tailscaleDismissed) return
        tailscaleStatus()?.let { message = it }
    }
    private fun tailscaleChanged() {
        if (!visible || destroyed) return
        val now = tailscale.connected()
        if (now) {
            handler.removeCallbacks(tailscaleTimeout); tailscaleDismissed = false
            if (tailscaleMessage()) showNotice(CONNECTED)
            if (!vpn) pairing()?.let { closeWarm(); reach(it) }
        } else if (vpn) { promptTailscale(); render() }
        vpn = now
    }
    private fun promptOffline() {
        if (!visible || active || undo || notice || offlineDismissed || !offline.active() || tailscaleStatus() != null) return
        message = ConnectionFailure.OFFLINE
    }
    /** null or a kind that isn't about reachability means the Mac answered, so the offline mark is dropped. */
    private fun noteReach(kind: ConnectionFailure.Kind?) {
        if (kind?.offline == true) {
            offline.failed(kind)
            handler.removeCallbacks(offlineExpiry); handler.postDelayed(offlineExpiry, offline.remaining())
            promptOffline()
        }
        else {
            offline.reachable(); offlineDismissed = false; handler.removeCallbacks(offlineExpiry)
            if (message == ConnectionFailure.OFFLINE) message = IDLE
        }
        render()
    }
    /** A mic tap while marked offline re-checks health for at most 3 s, then dictates or names the reason. A second tap skips the check. */
    private fun retry(paired: Pairing): Boolean {
        if (!offline.active()) return false
        if (checking) { checking = false; return false }
        checking = true; notice = true; message = ConnectionFailure.CHECKING; render()
        reach(paired, quick = true) { kind ->
            if (!checking) return@reach
            checking = false
            if (kind == null) { notice = false; message = IDLE; start() } else showNotice(tailscaleStatus() ?: kind.status)
        }
        return true
    }
    private fun quickOptions() {
        val anchor = strip?.mic ?: return
        android.widget.PopupMenu(anchor.context, anchor).apply {
            if (store.health.cleanupAvailable()) menu.add(if (store.correction) "Clean-up: on ✓" else "Clean-up: off").setOnMenuItemClickListener {
                store.correction = !store.correction; true
            } else menu.add("Mac has clean-up off").isEnabled = false
            if (store.health.cleanupAvailable()) {
                val selected = styleOverride ?: store.style(targetPackage).id
                CleanupStyles.profiles(store.health).forEach { profile ->
                    menu.add("Style · ${profile.name}" + (if (profile.rewrites) " · rewrites" else "") +
                        if (selected == profile.id) " ✓" else "").setOnMenuItemClickListener {
                        styleOverride = profile.id; currentStyle = profile; render(); true
                    }
                }
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
        visible = true
        val paired = pairing()
        tailnet = paired != null && TailscaleControl.routes(paired.base)
        if (tailnet) {
            vpn = tailscale.connected()
            tailscaleWatch?.close(); tailscaleWatch = tailscale.watch(::tailscaleChanged)
            promptTailscale()
        }
        promptOffline()
        render()
        if (paired != null) reach(paired)
    }
    private fun reach(paired: Pairing, quick: Boolean = false, then: ((ConnectionFailure.Kind?) -> Unit)? = null) {
        prewarm(paired)
        if (!checkHealth) { if (then != null) { noteReach(null); then(null) }; return }
        val id = ++version
        val call = ChirpNetwork.healthCall(client, paired)
        if (quick) call.timeout().timeout(3, java.util.concurrent.TimeUnit.SECONDS)
        ChirpNetwork.cancel(healthCall); healthCall = call
        scope.launch {
            try {
                val health = withContext(Dispatchers.IO) { healthCheck(call) }
                if (!visible || destroyed || version != id) return@launch
                healthCall = null; noteReach(null)
                if (tailscaleMessage()) { handler.removeCallbacks(tailscaleTimeout); notice = false; message = IDLE }
                store.health = health; retained = health.debugRetention; render()
                then?.invoke(null)
            } catch (e: Exception) {
                if (version != id || !visible || destroyed) return@launch
                healthCall = null
                val kind = ConnectionFailure.classify(e)
                noteReach(kind); then?.invoke(kind.takeIf { it.offline || it == ConnectionFailure.Kind.TLS })
            }
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
        if (retry(paired)) return
        checking = false
        val connection = host.currentInputConnection ?: return
        forgetUndo(); notice = false; started(); prepare()
        historyInfo = info; historyId = null
        currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == styleOverride } ?: store.style(targetPackage)
        insertionStart = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: minOf(info.initialSelStart, info.initialSelEnd)
        moved = false
        composing = ComposingSession(connection, insertionStart) { value ->
            android.text.SpannableString(value).apply {
                setSpan(android.text.style.UnderlineSpan(), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                val ink = VoicePalette.of(host).ink and 0x00ffffff or 0xbb000000.toInt()
                setSpan(android.text.style.ForegroundColorSpan(ink), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        composing?.shapeFinal(store.spokenCommands)
        secondsLeft = null; spokenLeft = null
        text = ""; pressAt = SystemClock.elapsedRealtime(); firstPartial = null; stopAt = null; finalLatency = null
        val stream = DictationStream(
            transportFactory = { event, failed -> takeTransport(paired, event, failed) },
            captureFactory = captureFactory,
            changed = { status, partial ->
                // The user just tried to dictate, so a dismissed Tailscale prompt may return as the reason.
                val kind = ConnectionFailure.kind(status)
                if (kind?.offline == true) noteReach(kind)
                message = if (kind != null) tailscaleStatus() ?: status else status
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
                noteReach(null); retained = it; store.health = store.health?.copy(debugRetention = it); render()
            },
            final = { land(it) },
            kept = { heard, reason -> land(ServerEvent.Final(heard, heard, false), reason) },
            correcting = { event ->
                partialFrames.clear()
                text = event.raw
                currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == event.profile } ?: currentStyle
                applying = true
                try { if (!moved) composing?.partial(ServerEvent.Partial(event.seq, event.raw, "")) } finally { applying = false }
            },
            pauseSeconds = store.autoStopSeconds, countdown = ::countdown,
            ended = {
                session = null; secondsLeft = null; spokenLeft = null
                warmEvent = null; warmFailure = null
                if (!notice && visible) { notice = true; handler.postDelayed(expiry, 5000) }
                if (!undo) { composing?.cancel(awayStart, selectionEnd); composing = null }
                text = ""; resync(selectionStart, selectionEnd)
                ChirpNetwork.release(client); render()
            },
        )
        session = stream
        stream.start(store.correction && store.health.cleanupAvailable(), currentStyle.id,
            instructions = "", prompt = store.promptEdits[currentStyle.id])
        haptic()
    }
    private val awayStart get() = if (moved) selectionStart else -1
    /** Commits a final, or what was heard before a failure ([reason]), and offers Undo for five seconds. */
    private fun land(result: ServerEvent.Final, reason: String? = null) {
        partialFrames.clear()
        val target = composing
        applying = true
        val inserted = try { target?.final(result, awayStart, selectionEnd) == true } finally { applying = false }
        if (inserted && target != null && target.selectionStart >= 0) { selectionStart = target.selectionStart; selectionEnd = target.selectionEnd }
        notice = inserted
        historyId = if (inserted) history?.record(result.text, result.raw.takeIf { result.corrected }, historyInfo, partial = reason != null) else null
        if (inserted) haptic()
        message = if (!inserted) reason ?: "Text field unavailable — try again"
            else if (reason != null) keptStatus(reason)
            else if (result.correctionError != null) "kept original"
            else if (result.corrected) "cleaned"
            else "Inserted · tap mic to dictate again"
        text = ""; finalLatency = stopAt?.let { SystemClock.elapsedRealtime() - it }
        undo = inserted && (target?.spanEnd ?: -1) >= 0
        if (notice) handler.postDelayed(expiry, 5000)
        if (!undo) { composing?.forgetUndo(); composing = null }
    }
    /** Reinserts a history entry through the same boundary/selection path as a dictated final. */
    fun insertText(value: String): Boolean {
        if (destroyed || value.isBlank()) return false
        if (active || undo) cancel()
        val connection = host.currentInputConnection ?: return false
        val info = host.currentInputEditorInfo
        prepare()
        val anchor = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: info?.let { minOf(it.initialSelStart, it.initialSelEnd) } ?: -1
        val insertion = ComposingSession(connection, anchor)
        applying = true
        val inserted = try { insertion.final(ServerEvent.Final(value, value, false)) } finally { applying = false }
        if (inserted && anchor >= 0) { selectionStart = insertion.selectionStart; selectionEnd = insertion.selectionEnd }
        resync(selectionStart, selectionEnd)
        if (inserted) haptic() else showNotice("Text field unavailable — try again")
        return inserted
    }
    private fun countdown(left: Int) {
        if (secondsLeft == null && store.haptics) strip?.mic?.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        secondsLeft = left
        // The status is a live region: speak the count only at a few marks, not every second.
        if (left in SPOKEN_MARKS) spokenLeft = left
        render()
    }
    private fun stop() { stopAt = SystemClock.elapsedRealtime(); session?.stop(); haptic(); render() }
    fun beforeEdit() {
        if (active || undo) cancel()
        else if (message == ConnectionFailure.OFFLINE) { offlineDismissed = true; message = IDLE; render() }
        else if (tailscaleMessage()) {
            // Typing past the prompt means "not now": give the suggestion row back.
            tailscaleDismissed = true; handler.removeCallbacks(tailscaleTimeout)
            notice = false; message = IDLE; render()
        }
    }
    fun selection(oldStart: Int, oldEnd: Int, start: Int, end: Int, composingStart: Int, composingEnd: Int) {
        selectionStart = start; selectionEnd = end
        if (applying) return
        if (active) {
            if (composingStart >= 0 && start == composingEnd && end == composingEnd) insertionStart = composingStart
            else if (start != oldStart || end != oldEnd) moveAway()
        } else if (undo && (start != composing?.selectionStart || end != composing?.selectionEnd)) {
            // forgetUndo cancels the expiry; keep the "cleaned" notice from pinning the row open.
            forgetUndo(); if (notice) handler.postDelayed(expiry, 5000); render()
        }
    }
    private fun moveAway() {
        moved = true; gesture.cancel(); partialFrames.clear()
        if (session?.stopping != true) { stopAt = SystemClock.elapsedRealtime(); session?.stop() }
        render()
    }
    fun cancel(status: String = "Tap mic · hold to talk") {
        gesture.cancel(); partialFrames.clear()
        // Clear editor composition before notifying HeliBoard that it can resume typing.
        applying = true
        try { composing?.cancel(awayStart, selectionEnd) } finally { applying = false }
        composing = null; forgetUndo()
        val old = session; session = null; old?.cancel()
        notice = false; message = status; text = ""; render()
    }
    private fun forgetUndo() { handler.removeCallbacks(expiry); undo = false; composing?.forgetUndo(); if (!active) composing = null }
    fun hidden() {
        visible = false; ++version; checking = false; ChirpNetwork.cancel(healthCall); healthCall = null
        tailscaleWatch?.close(); tailscaleWatch = null; handler.removeCallbacks(tailscaleTimeout)
        closeWarm(); cancel(); ChirpNetwork.release(client, cancel = true)
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
        val left = secondsLeft?.takeIf { active && session?.stopping != true }
        val shown = left?.let { "$message · $it s left" } ?: message
        val status = if (store.debugOverlay) "$shown · first ${firstPartial ?: "—"} ms · final ${finalLatency ?: "—"} ms" else shown
        val raw = undo && composing?.rawAvailable == true
        strip?.show(action()?.takeUnless { it.prompt }?.let { "$status · ${it.label}" } ?: status, "", active, session?.stopping == true, raw, retained || store.health?.debugRetention == true,
            polishing = session?.polishing == true, style = currentStyle.name, notice = notice, undoable = undo, offline = offline.active())
        strip?.status?.isClickable = action() != null || message == ConnectionFailure.OFFLINE
        val disclosure = if (retained || store.health?.debugRetention == true) "Debug retention on. " else ""
        strip?.status?.contentDescription = disclosure + (action()?.let { "$message. ${it.label}" }
            ?: if (message == ConnectionFailure.OFFLINE) ConnectionFailure.OFFLINE_DESCRIPTION
            else if (undo) "$status. ${if (raw) "Use raw or Undo" else "Undo"} available for five seconds."
            else if (left != null) spokenLeft?.let { "$message · $it s left" } ?: message else status)
    }
    private companion object {
        fun keptStatus(reason: String) = (if (DictationAction.forStatus(reason) == DictationAction.NETWORK ||
            reason.startsWith("Mac took too long")) "Connection lost" else reason.substringBefore(" — ")) + " — kept what I heard"
        const val IDLE = "Tap mic · hold to talk"
        const val CONNECTING = "Connecting Tailscale…"
        const val CONNECTED = "Tailscale connected"
        val SPOKEN_MARKS = setOf(15, 10, 5, 3, 2, 1)
    }
}
