package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class CorrectionDefaultsTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val local = Health(true, false, true, false, null)
    private val external = local.copy(correctionLeavesMachine = true, correctionHost = "cleanup.example.test")

    @Test fun `fresh on-Mac correction defaults on without recording a user choice`() {
        val store = SettingsStore(context)
        assertFalse(store.correction)
        store.health = local
        assertTrue(store.correction)
        assertTrue(SettingsStore(context).correction)
        assertFalse(context.getSharedPreferences("chirp", 0).contains("correction_explicit"))
    }
    @Test fun `external correction requires explicit opt-in and a known host`() {
        val store = SettingsStore(context)
        store.health = external
        assertFalse(store.correction)
        store.correction = true
        store.health = external.copy(debugRetention = true)
        assertTrue(store.correction)
        store.health = external.copy(correctionHost = null)
        assertFalse(store.correction)
    }
    @Test fun `explicit off survives local health refresh and new settings instances`() {
        val store = SettingsStore(context)
        store.health = local; store.correction = false
        repeat(3) { store.health = local.copy(debugRetention = it % 2 == 0) }
        assertFalse(store.correction)
        assertFalse(SettingsStore(context).correction)
        assertTrue(context.getSharedPreferences("chirp", 0).getBoolean("correction_explicit", false))
    }
    @Test fun `version 050 default false migrates to on-Mac default without treating old boolean as choice`() {
        context.getSharedPreferences("chirp", 0).edit()
            .putBoolean("correction", false)
            .putString("health", """{"ok":true,"ready":true,"debug_retention":false,"correction":"available","correction_leaves_machine":false}""")
            .apply()
        val upgraded = SettingsStore(context)
        assertTrue(upgraded.correction)
        upgraded.correction = false
        upgraded.health = local
        assertFalse(SettingsStore(context).correction)
    }
    @Test fun `legacy true never opts an external host in`() {
        context.getSharedPreferences("chirp", 0).edit().putBoolean("correction", true).apply()
        val store = SettingsStore(context); store.health = external
        assertFalse(store.correction)
    }
    @Test fun `availability drop stays off until the user explicitly enables again`() {
        val store = SettingsStore(context); store.health = local
        assertTrue(store.correction)
        store.health = local.copy(correctionAvailable = false)
        assertFalse(store.correction)
        store.health = local
        assertFalse(store.correction)
        store.correction = true
        assertTrue(store.correction)
    }
    @Test fun `destination changes revoke opt-in without losing an explicit off choice`() {
        val store = SettingsStore(context); store.health = local; store.correction = true
        store.health = external
        assertFalse(store.correction)
        store.correction = true
        store.health = external.copy(correctionHost = "changed.example.test")
        assertFalse(store.correction)
        store.correction = false
        store.health = local
        assertFalse(store.correction)
    }
}
