package dev.chirp.android

import android.content.Context
import androidx.core.content.edit
import android.annotation.SuppressLint
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    var correction: Boolean
        get() {
            val current = health
            if (!current.cleanupAvailable() || prefs.getBoolean("correction_suspended", false)) return false
            // 0.5.0 wrote a default false without recording consent. Only new explicit
            // choices override the on-Mac default; external correction remains opt-in.
            return if (prefs.getBoolean("correction_explicit", false)) prefs.getBoolean("correction", false)
                else current?.correctionLeavesMachine == false
        }
        set(value) { prefs.edit {
            putBoolean("correction", value)
            putBoolean("correction_explicit", true)
            putBoolean("correction_suspended", false)
        } }
    /** The first-run "Try it" card on Chirp settings was dismissed. */
    var tryItDismissed: Boolean
        get() = prefs.getBoolean("try_it_dismissed", false)
        set(value) { prefs.edit { putBoolean("try_it_dismissed", value) } }
    var defaultStyle: String
        get() = prefs.getString("default_style", "default") ?: "default"
        set(value) { require(CleanupStyles.validId(value)); prefs.edit { putString("default_style", value) } }
    var customInstructions: String
        get() = prefs.getString("custom_instructions", "").orEmpty()
        set(value) { prefs.edit { putString("custom_instructions", CleanupStyles.limitInstructions(value)) } }
    var appStyles: Map<String, String>
        get() = try {
            val saved = prefs.getString("app_styles", null)
            if (saved == null) CleanupStyles.defaults else JSONObject(saved).let { json ->
                json.keys().asSequence().associateWith { json.getString(it) }
            }
        } catch (_: Exception) { CleanupStyles.defaults }
        set(value) {
            require(value.all { (app, style) -> app.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+")) && CleanupStyles.validId(style) })
            prefs.edit { putString("app_styles", JSONObject(value).toString()) }
        }
    fun style(packageName: String?) = CleanupStyles.resolve(packageName, defaultStyle, appStyles, CleanupStyles.profiles(health))
    var promptEdits: Map<String, String>
        get() {
            val saved = prefs.getString("prompt_edits", null)
            if (saved == null) {
                val migrated = customInstructions.takeIf { it.isNotEmpty() }?.let { mapOf("custom" to it) }.orEmpty()
                promptEdits = migrated
                prefs.edit { remove("custom_instructions") }
                return migrated
            }
            return try { JSONObject(saved).let { json -> json.keys().asSequence().associateWith { json.getString(it) } } }
                catch (_: Exception) { emptyMap() }
        }
        set(value) {
            require(value.all { (id, prompt) -> CleanupStyles.validId(id) && CleanupStyles.characterCount(prompt) <= CleanupStyles.MAX_PROMPT })
            prefs.edit { putString("prompt_edits", JSONObject(value).toString()) }
        }
    var haptics: Boolean
        get() = prefs.getBoolean("haptics", true)
        set(value) { prefs.edit { putBoolean("haptics", value) } }
    var spokenCommands: Boolean
        get() = prefs.getBoolean("spoken_commands", false)
        set(value) { prefs.edit { putBoolean("spoken_commands", value) } }
    var stopOnPause: Boolean
        get() = prefs.getBoolean("stop_on_pause", false)
        set(value) { prefs.edit { putBoolean("stop_on_pause", value) } }
    var autoEnter: AutoEnterMode
        get() = AutoEnterMode.of(prefs.getString("auto_enter", null))
        set(value) { prefs.edit { putString("auto_enter", value.key) } }
    var pauseSeconds: Double
        get() = AutoStopDetector.nearest(prefs.getFloat("pause_seconds", AutoStopDetector.DEFAULT_SILENCE.toFloat()).toDouble())
        set(value) { prefs.edit { putFloat("pause_seconds", AutoStopDetector.nearest(value).toFloat()) } }
    /** The pause that ends a dictation on its own, or null when it stops only on tap. */
    val autoStopSeconds: Double? get() = pauseSeconds.takeIf { stopOnPause }
    var hardwareShortcut: Boolean
        get() = prefs.getBoolean("hardware_shortcut", true)
        set(value) { prefs.edit { putBoolean("hardware_shortcut", value) } }
    var soundCues: Boolean
        get() = prefs.getBoolean("sound_cues", false)
        set(value) { prefs.edit { putBoolean("sound_cues", value) } }
    var largerMic: Boolean
        get() = prefs.getBoolean("larger_mic", false)
        set(value) { prefs.edit { putBoolean("larger_mic", value) } }
    var returnToPrevious: Boolean
        get() = prefs.getBoolean("return_to_previous", false)
        set(value) { prefs.edit { putBoolean("return_to_previous", value) } }
    /** "App colours": wallpaper dynamic colour (default) or Chirp green, for the app and the floating mic. */
    var dynamicColor: Boolean
        get() = prefs.getBoolean("dynamic_color", true)
        set(value) { prefs.edit { putBoolean("dynamic_color", value) } }
    var debugOverlay: Boolean
        get() = prefs.getBoolean("overlay", false)
        set(value) { prefs.edit { putBoolean("overlay", value) } }
    /** Opt-in: when the Mac can't be reached, dictate with the phone's on-device recogniser. */
    var phoneFallback: Boolean
        get() = prefs.getBoolean("phone_fallback", false)
        set(value) { prefs.edit { putBoolean("phone_fallback", value) } }
    /** Notes: a sealed recovery copy of unsaved notes, on by default. */
    var notesRecovery: Boolean
        get() = prefs.getBoolean("notes_recovery", true)
        set(value) { prefs.edit { putBoolean("notes_recovery", value) } }
    /** Notes: skip screen work (live partials, the level meter, editor updates) while the screen is off. On by default. */
    var notesBatterySaver: Boolean
        get() = prefs.getBoolean("notes_battery_saver", true)
        set(value) { prefs.edit { putBoolean("notes_battery_saver", value) } }
    var health: Health?
        get() = try { prefs.getString("health", null)?.let(Protocol::health) } catch (_: Exception) { null }
        set(value) {
            val previous = health
            if (previous != null && (previous.cleanupAvailable() && !value.cleanupAvailable() ||
                    previous.correctionLeavesMachine != value?.correctionLeavesMachine ||
                    previous.correctionHost != value?.correctionHost)) {
                prefs.edit { putBoolean("correction_suspended", true) }
            }
            if (value == null) prefs.edit { remove("health") }
            else prefs.edit { putString("health", JSONObject().put("ok", true).put("ready", value.ready)
                .put("debug_retention", value.debugRetention).put("engine", value.engine.orEmpty())
                .put("correction", if (value.correctionAvailable) "available" else "off")
                .put("correction_leaves_machine", value.correctionLeavesMachine)
                .put("correction_host", value.correctionHost.orEmpty())
                .put("notes_structure", value.notesStructure).put("notes_reorganize", value.notesReorganize).put("notes_correction", value.notesCorrection)
                .put("correction_profiles", org.json.JSONArray().apply {
                    value.correctionProfiles.forEach { profile -> put(JSONObject().put("id", profile.id)
                        .put("name", profile.name).put("description", profile.description).put("rewrites", profile.rewrites)) }
                }).toString()) }
        }
    fun pairing(): Pairing? = try {
        val encrypted = prefs.getString("token", null)
        val iv = prefs.getString("iv", null)
        val url = prefs.getString("url", null)
        if (encrypted == null || iv == null || url == null) null else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            Pairing.from(url, String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), Charsets.UTF_8))
        }
    } catch (_: Exception) { null } // Key lost after reinstall/restore: pair again.

    @SuppressLint("UseKtx") // Need commit() success to guarantee encrypted credentials were persisted.
    fun save(pairing: Pairing, health: Health) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()) // Fresh random GCM IV on every write.
        val encrypted = cipher.doFinal(pairing.token.toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("url", pairing.base.toString())
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("token", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
        this.health = health
    }
    fun forget() {
        prefs.edit { clear() }
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(KEY_ALIAS) }
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    companion object {
        internal const val FILE = "chirp"
        private const val KEY_ALIAS = "chirp_pairing_v1"
    }
}
