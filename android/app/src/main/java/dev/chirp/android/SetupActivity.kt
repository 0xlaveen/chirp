package dev.chirp.android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.net.toUri
import android.os.Bundle
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class SetupState {
    var step by mutableIntStateOf(0)
    var wifiPermissionNeeded by mutableStateOf(false)
    var localNetwork by mutableStateOf(android.os.Build.VERSION.SDK_INT < 37)
    var mic by mutableStateOf(false)
    var inputEnabled by mutableStateOf(false)
    var bubbleEnabled by mutableStateOf(false)
    var inputSelected by mutableStateOf(false)
    var diagnostics by mutableStateOf("No crashes recorded")
    var paired by mutableStateOf(false)
    var status by mutableStateOf("Pair with your Mac to begin")
    var checking by mutableStateOf(false)
    var scanning by mutableStateOf(false)
    var link by mutableStateOf("")
    var host by mutableStateOf("")
    var health by mutableStateOf<Health?>(null)
    var correction by mutableStateOf(false)
    var haptics by mutableStateOf(true)
    var debug by mutableStateOf(false)
}

open class SetupActivity : ComponentActivity() {
    private lateinit var store: SettingsStore
    internal val state = SetupState()
    private var awaitingPrerequisite = false
    private var pairingGeneration = 0
    private var pendingHealth: okhttp3.Call? = null
    private val client by lazy { ChirpNetwork.client(this) }
    private var pendingNetworkTest: Boolean? = null
    private val networkPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        state.localNetwork = granted
        val pending = pendingNetworkTest; pendingNetworkTest = null
        if (granted && pending != null) testPairing(pending)
        else state.status = if (granted) "Wi-Fi server access allowed — test your pairing link" else "Wi-Fi server access denied. Tailscale still works; allow Wi-Fi access in app permissions if needed."
    }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        state.mic = it
        if (it) state.step = setupStep(state.inputEnabled, state.inputSelected, true, state.paired)
        state.status = if (it) "Microphone permission granted" else "Microphone permission is needed to dictate — open app permissions to allow it"
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)
        state.step = savedInstanceState?.getInt("step", 0)?.coerceIn(0, 3) ?: 0
        refresh()
        if (savedInstanceState == null) state.step = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired)
        consumeSection(intent)
        setContent {
            ChirpTheme {
                SetupWizard(state,
                    grantMic = {
                        if (state.mic) state.status = "Microphone permission already granted"
                        else micPermission.launch(Manifest.permission.RECORD_AUDIO)
                    },
                    keyboardSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) },
                    accessibilitySettings = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                    appSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri())) },
                    picker = { awaitingPrerequisite = true; getSystemService(InputMethodManager::class.java).showInputMethodPicker() },
                    grantNetwork = { networkPermission.launch(LOCAL_NETWORK_PERMISSION) },
                    keyboardPreferences = { startActivity(Intent(this, helium314.keyboard.settings.SettingsActivity::class.java)) },
                    diagnostics = { state.diagnostics = CrashLog(this).text() },
                    copyDiagnostics = {
                        getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(
                            android.content.ClipData.newPlainText("Chirp diagnostics", CrashLog(this).text()))
                    },
                    scan = ::scan, check = { testPairing(save = state.link.isNotBlank()) },
                    forget = {
                        ++pairingGeneration; pendingHealth?.cancel(); pendingHealth = null
                        store.forget(); state.link = ""; state.status = "Pairing removed"; state.checking = false; refresh()
                    },
                    preferences = {
                        store.correction = state.correction; store.haptics = state.haptics
                        store.debugOverlay = state.debug
                    },
                )
            }
        }
        consumePairingIntent(intent)
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); consumeSection(intent); consumePairingIntent(intent) }
    private fun consumeSection(source: Intent) {
        when (source.getStringExtra("section")) {
            "pair" -> state.step = 2
            "settings" -> state.step = 3
            "network" -> { state.step = 3; state.status = "Check Tailscale is connected on both devices, wake your Mac, and start Chirp on the Mac." }
        }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && awaitingPrerequisite && ::store.isInitialized) {
            refresh()
            state.step = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired)
            awaitingPrerequisite = false
        }
    }
    private fun consumePairingIntent(source: Intent) {
        val value = source.dataString
        source.data = null
        if (value != null) receivePairingLink(value)
    }
    private fun receivePairingLink(value: String?) {
        try {
            Pairing.parse(value ?: error("Missing pairing link"))
            ++pairingGeneration; pendingHealth?.cancel(); pendingHealth = null; state.checking = false
            state.link = value.orEmpty(); state.step = 2
            state.status = "Pairing link received — test to save"
        } catch (_: Exception) { state.status = "Invalid Chirp pairing link" }
    }
    internal fun scan() {
        state.scanning = true
        scanPairingQr(
            received = { if (!isDestroyed) { state.scanning = false; receivePairingLink(it) } },
            cancelled = { if (!isDestroyed) { state.scanning = false; state.status = "Scan cancelled — scan again or paste the pairing link" } },
            failed = { if (!isDestroyed) { state.scanning = false; state.status = "Scanner unavailable — check Google Play services or paste the pairing link" } },
        )
    }
    protected open fun scanPairingQr(received: (String?) -> Unit, cancelled: () -> Unit, failed: () -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { received(it.rawValue) }
            .addOnCanceledListener { cancelled() }
            .addOnFailureListener { failed() }
    }
    override fun onResume() {
        super.onResume()
        if (::store.isInitialized) { refresh(); if (state.paired && state.link.isBlank()) testPairing(save = false, requestPermission = false) }
    }
    override fun onSaveInstanceState(outState: Bundle) { outState.putInt("step", state.step); super.onSaveInstanceState(outState) }
    private fun refresh() {
        state.localNetwork = hasLocalNetworkAccess()
        state.mic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        state.inputEnabled = getSystemService(InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == packageName }
        state.inputSelected = ComponentName.unflattenFromString(Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty()) ==
            ComponentName(this, ChirpImeService::class.java)
        state.diagnostics = CrashLog(this).text()
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        state.bubbleEnabled = enabled.split(':').any {
            ComponentName.unflattenFromString(it) == ComponentName(this, ChirpAccessibilityService::class.java)
        }
        val pairing = store.pairing()
        state.paired = pairing != null
        state.host = pairing?.base?.host.orEmpty()
        state.health = store.health
        if (store.health?.let { !it.correctionAvailable || (it.correctionLeavesMachine && it.correctionHost == null) } != false) store.correction = false
        state.correction = store.correction
        state.haptics = store.haptics; state.debug = store.debugOverlay
    }
    internal fun testPairing(save: Boolean, requestPermission: Boolean = true) {
        val pairing = try {
            if (save) Pairing.parse(state.link) else store.pairing() ?: error("Missing pairing")
        } catch (_: Exception) { state.status = "Paste a valid Chirp pairing link with an HTTPS server"; return }
        state.wifiPermissionNeeded = false
        val id = ++pairingGeneration
        pendingHealth?.cancel()
        val call = ChirpNetwork.healthCall(client, pairing); pendingHealth = call
        state.checking = true; state.status = "Checking Mac…"
        lifecycleScope.launch {
            try {
                val health = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
                if (pairingGeneration != id) return@launch
                pendingHealth = null; state.checking = false
                if (save) { store.save(pairing, health); state.link = "" }
                else {
                    if (correctionLabel(store.health) != correctionLabel(health) || !health.correctionAvailable) store.correction = false
                    store.health = health
                }
                state.status = if (health.ready) "Mac ready" else "Paired · Mac is loading its speech model"
                refresh()
                if (save) state.step = 3
            } catch (error: Exception) {
                recordDebugNetworkFailure(this@SetupActivity, error)
                if (pairingGeneration == id && generateSequence<Throwable>(error) { it.cause }.take(5).any { it is WifiServerPermissionRequired }) {
                    pendingHealth = null; state.checking = false; state.wifiPermissionNeeded = true
                    state.status = "Local network access is needed only for servers on your Wi-Fi. Tailscale works without it."
                    if (requestPermission) { pendingNetworkTest = save; networkPermission.launch(LOCAL_NETWORK_PERMISSION) }
                    return@launch
                }
                if (pairingGeneration == id) {
                    pendingHealth = null; state.checking = false
                    state.status = "Mac unreachable — is Tailscale on? Check the Mac is awake, Chirp is running, and the pairing link is current."
                }
            }
        }
    }
    override fun onStop() {
        ++pairingGeneration; pendingHealth?.cancel(); pendingHealth = null; state.checking = false
        super.onStop()
    }
    override fun onDestroy() {
        state.link = ""; ++pairingGeneration; pendingHealth?.cancel(); ChirpNetwork.dispose(client); super.onDestroy()
    }
}
