package dev.chirp.android

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.app.Notification
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton

/** Opt-in, event-driven focused-field overlay. The system binding stays idle; no idle mic, socket or polling. */
@SuppressLint("SetTextI18n")
open class ChirpAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private val store by lazy { SettingsStore(this) }
    private val manager by lazy { getSystemService(WindowManager::class.java) }
    private val gesture = MicGesture()
    private var focused: AccessibilityNodeInfo? = null
    private var target: FocusedInsertion? = null
    private var overlay: FrameLayout? = null
    private var panel: VoicePanel? = null
    private var stream: DictationStream? = null
    private var client: okhttp3.OkHttpClient? = null
    private var pendingStart = false
    private var pendingStop = false
    private var expanded = false
    private var message = "Tap to dictate · hold to talk"
    private var partial = ""
    private var stable = ""
    private var raw: String? = null
    private var retained = false
    private var committing = false
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) onInterrupt()
            else if (intent?.action == Intent.ACTION_USER_PRESENT) {
                focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT); collapse()
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        ContextCompat.registerReceiver(this, screen, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
    }
    private fun locked() = getSystemService(KeyguardManager::class.java).isKeyguardLocked
    private val undoExpiry = Runnable { forgetUndo(); collapse() }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (locked()) { onInterrupt(); return }
        if (event.packageName == packageName && event.windowId == overlay?.createAccessibilityNodeInfo()?.windowId) return
        if ((event.eventType == AccessibilityEvent.TYPE_VIEW_FOCUSED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) && chirpKeyboardActive(this)) {
            cancel(); removeOverlay(); return
        }
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // A window transition must never carry a final into a different app, including the lockscreen.
                cancel()
                focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                collapse()
            }
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> {
                val source = event.source
                if (source == focused) return
                cancel(); focused = source?.takeIf { it.isEditable }; collapse()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                if (committing) return
                if (event.source != focused) return
                if ((stream != null || pendingStart) && target?.unchanged() != true) cancel()
                if (raw != null && target?.matchesFinal() != true) { forgetUndo(); collapse() }
                if (!expanded) position()
            }
            else -> Unit // Only the four configured event types are handled.
        }
    }
    override fun onServiceConnected() {
        super.onServiceConnected()
        focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        collapse()
    }
    private fun eligible(node: AccessibilityNodeInfo?): Boolean = node != null && node.isFocused && node.isEditable &&
        node.isEnabled && !node.isPassword && node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }

    @SuppressLint("ClickableViewAccessibility")
    private fun collapse() {
        expanded = false; panel = null
        val node = focused
        if (chirpKeyboardActive(this)) { cancel(); removeOverlay(); return }
        if (!eligible(node)) { removeOverlay(); return }
        val themed = ContextThemeWrapper(this, R.style.Theme_Chirp)
        val bubble = MaterialButton(themed).apply {
            text = ""; setIconResource(R.drawable.ic_mic); iconPadding = 0
            iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
            contentDescription = "Chirp microphone: tap to dictate, hold to talk"
            minWidth = 0; minimumWidth = 0; insetTop = 0; insetBottom = 0
            setPadding(0, 0, 0, 0); cornerRadius = dp(28)
            setOnClickListener { begin(); expand() }
            setOnTouchListener { _, event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> act(gesture.down(SystemClock.uptimeMillis(), stream != null || pendingStart))
                    MotionEvent.ACTION_UP -> { act(gesture.up(SystemClock.uptimeMillis())); expand() }
                    MotionEvent.ACTION_CANCEL -> act(gesture.cancel())
                }; true
            }
        }
        surface().apply { removeAllViews(); addView(bubble, FrameLayout.LayoutParams(dp(56), dp(56))) }
        position()
    }
    @SuppressLint("ClickableViewAccessibility")
    private fun expand() {
        expanded = true
        val view = VoicePanel(ContextThemeWrapper(this, R.style.Theme_Chirp))
        panel = view
        view.mic.setOnClickListener { if (stream == null && !pendingStart) begin() else stop() }
        view.mic.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> act(gesture.down(SystemClock.uptimeMillis(), stream != null || pendingStart))
                MotionEvent.ACTION_UP -> act(gesture.up(SystemClock.uptimeMillis()))
                MotionEvent.ACTION_CANCEL -> act(gesture.cancel())
            }; true
        }
        view.control("Cancel", "Cancel dictation and discard text") { cancel(); collapse() }
        view.control("Hide", "Hide panel") { cancel(); collapse() }
        // "Fix setup" only when setup is actually broken (spec §D): no pairing saved, or no microphone permission.
        val setupBroken = loadPairing() == null ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        if (setupBroken) view.control("Fix setup", "Open Chirp connection and permission troubleshooting") {
            cancel(); startActivity(Intent(this, SetupActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        view.raw.setOnClickListener {
            val text = raw ?: return@setOnClickListener
            committing = true
            val inserted = try { !locked() && target?.useRaw(text) == true } catch (_: RuntimeException) { false } finally { committing = false }
            if (inserted) { forgetUndo(); collapse() }
            else { forgetUndo(); message = "Text field changed — raw replacement unavailable"; render() }
        }
        surface().apply { removeAllViews(); addView(view) }
        render(); position()
    }
    private fun act(action: MicGesture.Action) {
        when (action) {
            MicGesture.Action.START -> begin()
            MicGesture.Action.STOP -> stop()
            MicGesture.Action.CANCEL -> cancel()
            MicGesture.Action.NONE -> Unit
        }
    }
    private fun begin() {
        if (stream != null || pendingStart) return
        if (locked()) { onInterrupt(); return }
        forgetUndo()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            message = "Allow microphone in Chirp settings"; render(); return
        }
        target = FocusedInsertion.from(focused)
        if (target == null) { message = "This field needs Chirp Keyboard — use the keyboard picker"; render(); return }
        if (loadPairing() == null) { target?.forget(); target = null; message = "Pair your Mac in Chirp settings"; render(); return }
        partial = ""; stable = ""; message = "Connecting to Mac…"
        pendingStart = true; pendingStop = false
        try {
            // AOSP binds accessibility with INCLUDE_CAPABILITIES and ALLOW_BACKGROUND_ACTIVITY_STARTS.
            // Still promote explicitly as a microphone FGS and handle OEM/permission denial without recording.
            ContextCompat.startForegroundService(this, Intent(this, ChirpAccessibilityService::class.java).setAction(START))
        } catch (_: RuntimeException) {
            pendingStart = false; target?.forget(); target = null
            message = "Microphone start blocked — open Chirp settings or use Chirp Keyboard"
        }
        render()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CANCEL) { cancel(); collapse(); return START_NOT_STICKY }
        if (intent?.action != START || !pendingStart || target?.unchanged() != true) {
            cancel(); return START_NOT_STICKY
        }
        try {
            val notifications = getSystemService(NotificationManager::class.java)
            notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Dictation microphone", NotificationManager.IMPORTANCE_LOW))
            val cancel = PendingIntent.getService(this, 0, Intent(this, ChirpAccessibilityService::class.java).setAction(CANCEL),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification = Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_chirp_notification)
                .setContentTitle("Chirp microphone active").setContentText("Tap Cancel to discard dictation")
                .setOngoing(true).addAction(Notification.Action.Builder(null, "Cancel", cancel).build()).build()
            startForeground(12, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            val paired = loadPairing() ?: error("Pairing required")
            val network = ChirpNetwork.client(this); client = network
            val session = DictationStream(
                transportFactory = { event, failure -> createTransport(network, paired, event, failure) },
                captureFactory = ::createCapture,
                changed = { status, event ->
                    message = status
                    if (event != null) { partial = event.text; stable = event.stable }
                    render()
                },
                level = { panel?.level(it) },
                retention = { retained = it; store.health = store.health?.copy(debugRetention = it); render() },
                final = { result ->
                    committing = true
                    val inserted = try { !locked() && target?.insert(result.text) == true } catch (_: RuntimeException) { false } finally { committing = false }
                    partial = ""; stable = ""
                    message = if (inserted) "Inserted" else "Text field changed — nothing inserted"
                    if (inserted && result.corrected && result.text != result.raw) {
                        raw = result.raw; handler.postDelayed(undoExpiry, 5000)
                    } else { target?.forget(); target = null }
                },
                ended = {
                    stream = null; pendingStart = false
                    partial = ""; stable = ""
                    client?.let(ChirpNetwork::dispose); client = null
                    stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
                    if (raw == null) { target?.forget(); target = null }
                    render()
                },
            )
            stream = session; pendingStart = false
            session.start(store.correction)
            haptic()
            if (pendingStop) session.stop()
        } catch (_: RuntimeException) {
            cancel(); message = "Microphone start blocked — open Chirp settings or use Chirp Keyboard"; render()
        }
        return START_NOT_STICKY
    }
    protected open fun loadPairing(): Pairing? = store.pairing()
    protected open fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit): Capture =
        PcmCapture(frame, level, done)
    protected open fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
        StreamTransport(client, pairing, dispatch = { callback -> handler.post { callback() } }, event = event, failure = failure)
    private fun stop() {
        pendingStop = true; stream?.stop(); haptic(); render()
    }
    private fun cancel() {
        pendingStart = false; pendingStop = false
        val old = stream; stream = null; old?.cancel()
        client?.let(ChirpNetwork::dispose); client = null
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        forgetUndo(); target?.forget(); target = null
        partial = ""; stable = ""; message = "Tap to dictate · hold to talk"; render()
    }
    private fun forgetUndo() {
        handler.removeCallbacks(undoExpiry); raw = null
        if (stream == null && !pendingStart) { target?.forget(); target = null }
    }
    private fun haptic() { if (store.haptics) overlay?.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
    private fun render() {
        panel?.apply {
            show(message, partial, stable, stream != null || pendingStart, stream?.stopping == true || (pendingStart && pendingStop))
            banner.retention(retained || store.health?.debugRetention == true)
            raw.visibility = if (this@ChirpAccessibilityService.raw != null) View.VISIBLE else View.GONE
        }
    }
    private fun surface(): FrameLayout {
        overlay?.let { return it }
        return FrameLayout(this).also {
            overlay = it
            manager.addView(it, layout())
        }
    }
    private fun layout(): WindowManager.LayoutParams {
        val bounds = manager.currentWindowMetrics.bounds
        val rect = Rect(); focused?.getBoundsInScreen(rect)
        return WindowManager.LayoutParams(
            if (expanded) minOf(dp(360), bounds.width() - dp(24)) else dp(56),
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = dp(12)
            y = (if (expanded) rect.top - dp(340) else rect.bottom - dp(56)).coerceIn(dp(32), maxOf(dp(32), bounds.height() - dp(if (expanded) 400 else 88)))
            title = "Chirp voice controls"
        }
    }
    private fun position() { overlay?.let { manager.updateViewLayout(it, layout()) } }
    private fun removeOverlay() { overlay?.let { manager.removeView(it) }; overlay = null; panel = null }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (expanded) expand() else collapse()
    }
    override fun onInterrupt() { cancel(); focused = null; removeOverlay() }
    override fun onUnbind(intent: Intent?): Boolean { onInterrupt(); return super.onUnbind(intent) }
    override fun onDestroy() {
        onInterrupt(); unregisterReceiver(screen); handler.removeCallbacksAndMessages(null); super.onDestroy()
    }
    companion object {
        private const val START = "dev.chirp.android.START_DICTATION"
        private const val CANCEL = "dev.chirp.android.CANCEL_DICTATION"
        private const val CHANNEL = "dictation"
    }
}
