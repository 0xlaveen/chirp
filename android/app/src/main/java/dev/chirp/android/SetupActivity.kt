package dev.chirp.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@SuppressLint("SetTextI18n")
class SetupActivity : ComponentActivity() {
    private lateinit var store: SettingsStore
    private lateinit var banner: TextView
    private lateinit var status: TextView
    private lateinit var link: EditText
    private lateinit var correction: CheckBox
    private var pairingGeneration = 0
    private var pendingHealth: okhttp3.Call? = null
    private val client by lazy { ChirpNetwork.client() }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        status.text = if (it) "Microphone permission granted" else "Microphone permission is needed to dictate"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)
        val content = column()
        content.addView(label("Chirp Voice", 28f))
        content.addView(label("Speak on your phone. Your Mac transcribes over Tailscale."))
        banner = label("").also { content.addView(it) }
        status = label(if (store.pairing() == null) "Pair with your Mac to begin" else "Paired with ${store.pairing()?.base?.host}")
        content.addView(status)
        content.button("1 · Grant microphone permission") {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                status.text = "Microphone permission already granted"
            else micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
        content.button("2 · Enable Chirp in keyboard settings") { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        content.button("3 · Pick Chirp Voice") { getSystemService(InputMethodManager::class.java).showInputMethodPicker() }
        content.addView(label("4 · Connect Tailscale on both devices. On the Mac run chirp-server pair, then paste its pairing link here."))
        link = EditText(this).apply {
            hint = "chirp://pair?url=…&token=…"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isSingleLine = true; isSaveEnabled = false
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        content.addView(link)
        val test = content.button("Test connection & save pairing") { testPairing() }
        test.contentDescription = "Test the Mac connection and securely save the pairing"
        correction = CheckBox(this).apply {
            isChecked = store.correction
            setOnCheckedChangeListener { _, value -> store.correction = value }
        }
        content.addView(correction)
        content.addView(CheckBox(this).apply {
            text = "Return to previous keyboard after dictation"; isChecked = store.returnToPrevious
            setOnCheckedChangeListener { _, value -> store.returnToPrevious = value }
        })
        content.addView(CheckBox(this).apply {
            text = "Haptic cues"; isChecked = store.haptics
            setOnCheckedChangeListener { _, value -> store.haptics = value }
        })
        content.addView(CheckBox(this).apply {
            text = "Debug overlay (timings only)"; isChecked = store.debugOverlay
            setOnCheckedChangeListener { _, value -> store.debugOverlay = value }
        })
        content.addView(label("5 · Test dictation below: tap the field, pick Chirp Voice and tap the mic. Hold for push-to-talk. ✕ discards the utterance."))
        content.addView(EditText(this).apply {
            hint = "Test dictation here"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            minLines = 3; isSaveEnabled = false
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        })
        content.button("Forget pairing") { ++pairingGeneration; pendingHealth?.cancel(); store.forget(); link.text.clear(); refresh(); status.text = "Pairing removed" }
        setContentView(ScrollView(this).apply { addView(content); systemInsets() })
        consumePairingIntent(intent)
        refresh()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumePairingIntent(intent)
    }
    private fun consumePairingIntent(source: Intent) {
        val value = source.dataString
        source.data = null // Do not keep credential-bearing intents in app state.
        if (value != null) {
            try { Pairing.parse(value); link.setText(value); status.text = "Pairing link received — test to save" }
            catch (_: Exception) { status.text = "Invalid Chirp pairing link" }
        }
    }
    override fun onResume() { super.onResume(); if (::store.isInitialized) refresh() }
    private fun refresh() {
        banner.retention(store.health?.debugRetention == true)
        correction.text = correctionLabel(store.health)
        correction.isEnabled = store.health?.let { it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null) } == true
        if (!correction.isEnabled) store.correction = false
        correction.isChecked = store.correction
    }
    private fun testPairing() {
        val pairing = try {
            if (link.text.isNullOrBlank()) store.pairing() ?: error("Missing pairing") else Pairing.parse(link.text.toString())
        } catch (_: Exception) { status.text = "Paste a valid Chirp pairing link with an HTTPS server"; return }
        val id = ++pairingGeneration
        pendingHealth?.cancel()
        val call = ChirpNetwork.healthCall(client, pairing)
        pendingHealth = call
        status.text = "Checking Mac…"
        lifecycleScope.launch {
            try {
                val started = android.os.SystemClock.elapsedRealtime()
                val health = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
                if (pairingGeneration != id) return@launch
                pendingHealth = null
                store.save(pairing, health)
                link.text.clear()
                status.text = if (health.ready) if (store.debugOverlay) "Mac ready · round trip ${android.os.SystemClock.elapsedRealtime() - started} ms" else "Mac ready"
                    else "Paired · Mac is loading its speech model"
                refresh()
            } catch (_: Exception) { if (pairingGeneration == id) status.text = "Mac unreachable or pairing refused — check Tailscale and the pairing link" }
        }
    }
    override fun onDestroy() { ++pairingGeneration; pendingHealth?.cancel(); ChirpNetwork.dispose(client); super.onDestroy() }
}
