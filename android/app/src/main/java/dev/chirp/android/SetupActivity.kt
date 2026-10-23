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
import dev.chirp.android.settings.SettingsActions
import dev.chirp.android.settings.SettingsPage
import dev.chirp.android.settings.SettingsScreen
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class SetupState {
    /** The onboarding page (`PAGE_*`). */
    var step by mutableIntStateOf(PAGE_WELCOME)
    /** The page onboarding opened on: back stops here instead of walking through pages the entry skipped. */
    var entryStep by mutableIntStateOf(PAGE_WELCOME)
    var micDenied by mutableStateOf(false)
    /** A pairing was tested and saved in this onboarding run; the pair page shows it instead of the scanner. */
    var connected by mutableStateOf(false)
    var pairIssue by mutableStateOf<PairIssue?>(null)
    /** Settings opens with the first-run "Try it" card on top. */
    var tryIt by mutableStateOf(false)
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
    /** Result of the last Mac check: null until one finishes. */
    var reachable by mutableStateOf<Boolean?>(null)
    var settingsOpen by mutableStateOf(false)
    var settingsPage by mutableStateOf<SettingsPage?>(null)
}

open class SetupActivity : ComponentActivity() {
    private lateinit var store: SettingsStore
    internal val state = SetupState()
    private var awaitingPrerequisite = false
    private var pairingGeneration = 0
    private var pendingHealth: okhttp3.Call? = null
    private val client by lazy { ChirpNetwork.client(this) }
    private var pendingNetworkTest: Boolean? = null
    /** Settings opened by an intent (HeliBoard, the keyboard, a recovery link) rather than from setup: back leaves the app instead of returning to setup. */
    private var settingsStandalone = false
    private val networkPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        state.localNetwork = granted
        val pending = pendingNetworkTest; pendingNetworkTest = null
        if (granted && pending != null) testPairing(pending)
        else state.status = if (granted) "Wi-Fi server access allowed — test your pairing link" else "Wi-Fi server access denied. Tailscale still works; allow Wi-Fi access in app permissions if needed."
    }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        state.mic = it; state.micDenied = !it
        if (it) advance()
        state.status = if (it) "Microphone permission granted" else "Microphone permission is needed to dictate — open app permissions to allow it"
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)
        state.step = savedInstanceState?.getInt("step", 0)?.coerceIn(PAGE_WELCOME, PAGE_PAIR) ?: PAGE_WELCOME
        savedInstanceState?.let {
            state.entryStep = it.getInt("entry", 0).coerceIn(PAGE_WELCOME, PAGE_PAIR); state.connected = it.getBoolean("connected"); state.tryIt = it.getBoolean("try_it")
            state.settingsOpen = it.getBoolean("settings"); settingsStandalone = it.getBoolean("standalone")
            state.settingsPage = it.getString("settings_page")?.let { name -> SettingsPage.entries.firstOrNull { page -> page.name == name } }
        }
        refresh()
        if (savedInstanceState == null) {
            val first = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired, welcomed = false)
            if (first == ONBOARDING_DONE) finishOnboarding() else { state.step = first; state.entryStep = first }
        }
        consumeSection(intent)
        setContent {
            ChirpTheme {
                if (state.settingsOpen) SettingsScreen(state, SettingsActions(
                    checkConnection = { testPairing(save = false) },
                    changePairing = ::openPairing,
                    forgetPairing = ::forgetPairing,
                    allowWifi = { networkPermission.launch(LOCAL_NETWORK_PERMISSION) },
                    floatingMicSettings = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                    keyboardPreferences = ::openKeyboardPreferences,
                ), initialPage = state.settingsPage, onExit = if (settingsStandalone) null else ({ state.settingsOpen = false }))
                else Onboarding(state, OnboardingActions(
                    grantMic = {
                        if (state.mic) state.status = "Microphone permission already granted"
                        else micPermission.launch(Manifest.permission.RECORD_AUDIO)
                    },
                    keyboardSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) },
                    appSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri())) },
                    picker = { awaitingPrerequisite = true; getSystemService(InputMethodManager::class.java).showInputMethodPicker() },
                    grantNetwork = { networkPermission.launch(LOCAL_NETWORK_PERMISSION) },
                    scan = ::scan, pasteLink = ::editLink, retry = { if (state.link.isBlank()) scan() else testPairing(save = true) },
                    openTailscale = { AndroidTailscale(this).open() }, finish = ::advance,
                ))
            }
        }
        consumePairingIntent(intent)
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); consumeSection(intent); consumePairingIntent(intent) }
    private fun openKeyboardPreferences() = startActivity(Intent(this, helium314.keyboard.settings.SettingsActivity::class.java))
    private fun forgetPairing() {
        ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null
        store.forget(); state.link = ""; state.status = "Pairing removed"; state.checking = false; state.reachable = null; state.connected = false; refresh()
    }
    /** Onboarding is complete: hand over to Chirp settings, with the first-run "Try it" card until it's dismissed. */
    private fun finishOnboarding() {
        state.tryIt = !store.tryItDismissed; state.settingsPage = null; settingsStandalone = true; state.settingsOpen = true
    }
    /** Moves to the first page whose requirement isn't met, or finishes. Never back to the welcome page once past it. */
    internal fun advance() {
        val next = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired, welcomed = state.step > PAGE_WELCOME)
        if (next == ONBOARDING_DONE) finishOnboarding() else state.step = next
    }
    /** Opens the pair page on its own: from settings (Change pairing), a pairing link or a recovery action. Back leaves it. */
    private fun openPairing() {
        if (state.settingsOpen) state.entryStep = PAGE_PAIR
        state.settingsOpen = false; state.step = PAGE_PAIR; state.connected = false; state.pairIssue = null
    }
    private fun openSettings(page: SettingsPage?) { state.settingsPage = page; settingsStandalone = true; state.settingsOpen = true }
    private fun consumeSection(source: Intent) {
        when (source.getStringExtra("section")) {
            "pair" -> openPairing()
            "settings" -> openSettings(null)
            "try" -> { state.tryIt = true; openSettings(null) }
            "connection" -> openSettings(SettingsPage.Connection)
            "network" -> { state.reachable = false; openSettings(SettingsPage.Connection) }
        }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && awaitingPrerequisite && ::store.isInitialized) {
            refresh()
            if (!state.settingsOpen) advance()
            awaitingPrerequisite = false
        }
    }
    private fun consumePairingIntent(source: Intent) {
        val value = source.dataString
        source.data = null
        if (value != null) receivePairingLink(value)
    }
    /** A scanned code or opened link: test it and save it, with no further tap. The token reaches prefs only after the Mac answers. */
    private fun receivePairingLink(value: String?) {
        try {
            Pairing.parse(value ?: error("Missing pairing link"))
            ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null; state.checking = false
            state.link = value.orEmpty(); openPairing()
            testPairing(save = true)
        } catch (_: Exception) { state.status = "Invalid Chirp pairing link"; state.pairIssue = PairIssue.InvalidLink }
    }
    /** The paste field: a pasted link that parses is tested and saved straight away. */
    internal fun editLink(value: String) {
        state.link = value; state.pairIssue = null
        if (runCatching { Pairing.parse(value) }.isSuccess) testPairing(save = true)
    }
    internal fun scan() {
        state.scanning = true; state.pairIssue = null
        scanPairingQr(
            received = { if (!isDestroyed) { state.scanning = false; receivePairingLink(it) } },
            cancelled = { if (!isDestroyed) { state.scanning = false; state.status = "Scan cancelled — scan again or paste the pairing link" } },
            failed = { if (!isDestroyed) { state.scanning = false; state.pairIssue = PairIssue.ScannerUnavailable
                state.status = "Scanner unavailable — check Google Play services or paste the pairing link" } },
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
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("step", state.step); outState.putInt("entry", state.entryStep); outState.putBoolean("connected", state.connected)
        outState.putBoolean("try_it", state.tryIt); outState.putBoolean("settings", state.settingsOpen); outState.putBoolean("standalone", settingsStandalone)
        outState.putString("settings_page", state.settingsPage?.name)
        super.onSaveInstanceState(outState)
    }
    private fun refresh() {
        state.localNetwork = hasLocalNetworkAccess()
        state.mic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        state.inputEnabled = getSystemService(InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == packageName }
        state.inputSelected = ComponentName.unflattenFromString(Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty()) ==
            ComponentName(this, ChirpImeService::class.java)
        state.diagnostics = DiagnosticsReport.text(this)
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        state.bubbleEnabled = enabled.split(':').any {
            ComponentName.unflattenFromString(it) == ComponentName(this, ChirpAccessibilityService::class.java)
        }
        val pairing = store.pairing()
        state.paired = pairing != null
        state.host = pairing?.base?.host.orEmpty()
        state.health = store.health
    }
    internal fun testPairing(save: Boolean, requestPermission: Boolean = true) {
        val pairing = try {
            if (save) Pairing.parse(state.link) else store.pairing() ?: error("Missing pairing")
        } catch (_: Exception) { state.status = "Paste a valid Chirp pairing link with an HTTPS server"; return }
        state.wifiPermissionNeeded = false
        val id = ++pairingGeneration
        ChirpNetwork.cancel(pendingHealth)
        val call = ChirpNetwork.healthCall(client, pairing); pendingHealth = call
        state.checking = true; state.pairIssue = null; state.status = "Checking Mac…"
        lifecycleScope.launch {
            try {
                val health = checkMac(call)
                if (pairingGeneration != id) return@launch
                pendingHealth = null; state.checking = false
                if (save) { savePairing(pairing, health); state.link = "" }
                else {
                    store.health = health
                }
                state.reachable = true
                state.status = if (health.ready) "Mac ready" else "Paired · Mac is loading its speech model"
                refresh()
                if (save) state.connected = true
            } catch (error: Exception) {
                recordDebugNetworkFailure(this@SetupActivity, error)
                if (pairingGeneration == id && generateSequence<Throwable>(error) { it.cause }.take(5).any { it is WifiServerPermissionRequired }) {
                    pendingHealth = null; state.checking = false; state.wifiPermissionNeeded = true
                    state.status = "Local network access is needed only for servers on your Wi-Fi. Tailscale works without it."
                    if (requestPermission) { pendingNetworkTest = save; networkPermission.launch(LOCAL_NETWORK_PERMISSION) }
                    return@launch
                }
                if (pairingGeneration == id) {
                    pendingHealth = null; state.checking = false; state.reachable = false; if (save) state.pairIssue = PairIssue.Unreachable
                    state.status = "Mac unreachable — is Tailscale on? Check the Mac is awake, Chirp is running, and the pairing link is current."
                }
            }
        }
    }
    protected open suspend fun checkMac(call: okhttp3.Call): Health = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
    protected open fun savePairing(pairing: Pairing, health: Health) = store.save(pairing, health)
    override fun onStop() {
        ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null; state.checking = false
        super.onStop()
    }
    override fun onDestroy() {
        state.link = ""; ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); ChirpNetwork.dispose(client); super.onDestroy()
    }
}
