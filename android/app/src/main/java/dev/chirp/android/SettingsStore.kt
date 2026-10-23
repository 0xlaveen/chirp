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
    private val prefs = context.getSharedPreferences("chirp", Context.MODE_PRIVATE)
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
    var returnToPrevious: Boolean
        get() = prefs.getBoolean("return_to_previous", false)
        set(value) { prefs.edit { putBoolean("return_to_previous", value) } }
    var debugOverlay: Boolean
        get() = prefs.getBoolean("overlay", false)
        set(value) { prefs.edit { putBoolean("overlay", value) } }
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
    companion object { private const val KEY_ALIAS = "chirp_pairing_v1" }
}
