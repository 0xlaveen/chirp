package dev.chirp.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Looper
import dev.chirp.android.settings.SettingsPage
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class SetupActivityTest {
    class TestSetup : SetupActivity() {
        lateinit var received: (String?) -> Unit
        lateinit var cancelled: () -> Unit
        lateinit var failed: () -> Unit
        var scans = 0
        var mac: () -> Health = { Health(true, false, true, false, null, engine = "Parakeet") }
        var saved: Pair<Pairing, Health>? = null
        /** The Mac's answer waits for the test, as a real network call would. */
        var gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        override suspend fun checkMac(call: okhttp3.Call): Health { gate.await(); return mac() }
        override fun savePairing(pairing: Pairing, health: Health) { saved = pairing to health } // Robolectric has no AndroidKeyStore.
        override fun scanPairingQr(received: (String?) -> Unit, cancelled: () -> Unit, failed: () -> Unit) {
            scans++; this.received = received; this.cancelled = cancelled; this.failed = failed
        }
    }
    private lateinit var controller: ActivityController<TestSetup>
    private lateinit var activity: TestSetup
    private val syntheticLink = "chirp://pair?url=https%3A%2F%2Fmac.example.test%2Fchirp&token=synthetic%2Btoken%3D"
    private fun shows(text: String) = activity.state.status.contains(text)
    private fun scan() = activity.scan()
    @Before fun setUp() {
        controller = Robolectric.buildActivity(TestSetup::class.java).setup()
        activity = controller.get()
    }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    private fun idle() { activity.gate.complete(Unit); shadowOf(Looper.getMainLooper()).idle() }
    private fun prefs() = activity.getSharedPreferences("chirp", 0)

    @Test fun `first run opens on the welcome page`() {
        assertEquals(PAGE_WELCOME, activity.state.step); assertEquals(PAGE_WELCOME, activity.state.entryStep)
        assertFalse(activity.state.settingsOpen); assertFalse(activity.state.connected)
    }
    @Test fun `a scanned code is tested and saved without another tap, and only after the Mac answers`() {
        scan(); assertEquals(1, activity.scans); assertTrue(activity.state.scanning)
        activity.received(syntheticLink)
        assertFalse(activity.state.scanning); assertEquals(syntheticLink, activity.state.link); assertEquals(PAGE_PAIR, activity.state.step)
        assertTrue(activity.state.checking); assertTrue(shows("Checking Mac")); assertNull(activity.saved)
        assertFalse(prefs().contains("token"))
        idle()
        val (pairing, health) = activity.saved!!
        assertEquals("https://mac.example.test/chirp/v1/health", pairing.endpoint("v1/health").toString())
        assertEquals("synthetic+token=", pairing.token); assertEquals("Parakeet", health.engine)
        assertFalse(activity.state.checking); assertTrue(activity.state.connected); assertEquals(true, activity.state.reachable)
        assertEquals("", activity.state.link); assertNull(activity.state.pairIssue)
    }
    @Test fun `an unreachable Mac saves nothing, keeps the link for a retry and offers one action`() {
        activity.mac = { throw java.io.IOException("synthetic") }
        scan(); activity.received(syntheticLink); idle()
        assertNull(activity.saved); assertFalse(prefs().contains("token"))
        assertEquals(PairIssue.Unreachable, activity.state.pairIssue); assertEquals(false, activity.state.reachable)
        assertFalse(activity.state.connected); assertFalse(activity.state.checking); assertEquals(syntheticLink, activity.state.link)
        activity.mac = { Health(true, false, true, false, null, engine = "Parakeet") }
        activity.gate = kotlinx.coroutines.CompletableDeferred()
        activity.testPairing(save = true); assertNull(activity.state.pairIssue); idle()
        assertNotNull(activity.saved); assertTrue(activity.state.connected)
    }
    @Test fun `a pasted link that parses is saved, anything else is not tested`() {
        activity.editLink("not a link"); assertFalse(activity.state.checking); assertEquals("not a link", activity.state.link)
        activity.editLink(syntheticLink); assertTrue(activity.state.checking); idle()
        assertNotNull(activity.saved); assertTrue(activity.state.connected)
    }
    @Test fun `scanner rejects missing malformed non pairing and insecure payloads`() {
        listOf(null, "", "https://example.test", "chirp://pair?url=http://mac.example.test&token=synthetic",
            "chirp://pair?url=https://mac.example.test&token=a&token=b").forEach { value ->
            scan(); activity.received(value)
            assertEquals("", activity.state.link); assertTrue(shows("Invalid Chirp pairing link")); assertEquals(PairIssue.InvalidLink, activity.state.pairIssue)
            assertFalse(activity.state.scanning); assertFalse(activity.state.checking)
        }
        idle(); assertNull(activity.saved)
    }
    @Test fun `cancel leaves the page as it was and scanner failure points at pasting`() {
        activity.state.link = syntheticLink
        scan(); activity.cancelled()
        assertFalse(activity.state.scanning); assertTrue(shows("Scan cancelled")); assertEquals(syntheticLink, activity.state.link); assertNull(activity.state.pairIssue)
        scan(); activity.failed()
        assertFalse(activity.state.scanning); assertTrue(shows("check Google Play services")); assertEquals(syntheticLink, activity.state.link)
        assertEquals(PairIssue.ScannerUnavailable, activity.state.pairIssue)
    }
    @Test fun `deep links share the scan path and clear the credential intent`() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink))
        controller.newIntent(intent)
        assertNull(intent.data); assertEquals(syntheticLink, activity.state.link); assertEquals(PAGE_PAIR, activity.state.step)
        assertTrue(activity.state.checking); idle(); assertNotNull(activity.saved)
        val invalid = Intent(Intent.ACTION_VIEW, Uri.parse("chirp://pair?url=http://mac.example.test&token=synthetic"))
        controller.newIntent(invalid)
        assertNull(invalid.data); assertTrue(shows("Invalid Chirp pairing link"))
    }
    @Test fun `section intents open the pairing page, the settings tree or its connection page`() {
        activity.state.step = PAGE_MIC
        controller.newIntent(Intent().putExtra("section", "settings"))
        assertTrue(activity.state.settingsOpen); assertNull(activity.state.settingsPage)
        controller.newIntent(Intent().putExtra("section", "pair"))
        assertFalse(activity.state.settingsOpen); assertEquals(PAGE_PAIR, activity.state.step)
        assertEquals("back from a pair-only page leaves the app", PAGE_PAIR, activity.state.entryStep)
        controller.newIntent(Intent().putExtra("section", "connection"))
        assertTrue(activity.state.settingsOpen); assertEquals(SettingsPage.Connection, activity.state.settingsPage)
        controller.newIntent(Intent().putExtra("section", "try")); assertTrue(activity.state.tryIt); assertNull(activity.state.settingsPage)
        controller.newIntent(Intent().putExtra("section", "network"))
        assertEquals(SettingsPage.Connection, activity.state.settingsPage); assertEquals(false, activity.state.reachable)
    }
    @Test fun `a pairing link closes settings and goes to the pair page`() {
        controller.newIntent(Intent().putExtra("section", "settings"))
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink)))
        assertFalse(activity.state.settingsOpen); assertEquals(PAGE_PAIR, activity.state.step)
    }
    @Test fun `advancing goes to the first unmet page and finishing opens settings with the Try it card until dismissed`() {
        val state = activity.state
        state.step = PAGE_KEYBOARD; state.inputEnabled = true; state.inputSelected = true
        activity.advance(); assertEquals(PAGE_MIC, state.step); assertFalse(state.settingsOpen)
        state.mic = true; activity.advance(); assertEquals(PAGE_PAIR, state.step)
        state.paired = true; activity.advance()
        assertTrue(state.settingsOpen); assertNull(state.settingsPage); assertTrue(state.tryIt)
        state.settingsOpen = false; state.tryIt = false
        SettingsStore(activity).tryItDismissed = true
        activity.advance(); assertTrue(state.settingsOpen); assertFalse(state.tryIt)
    }
    @Test fun `late scan result cannot feed a destroyed activity`() {
        scan()
        controller.pause().stop().destroy()
        activity.received(syntheticLink)
        assertEquals("", activity.state.link)
    }
    @Test fun `app does not request camera permission`() {
        val info = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
        assertFalse(info.requestedPermissions.orEmpty().contains(Manifest.permission.CAMERA))
    }
    @Test @Config(sdk = [37]) fun `Android 17 denial does not gate a Tailscale pairing connection`() {
        org.robolectric.Shadows.shadowOf(org.robolectric.RuntimeEnvironment.getApplication()).denyPermissions(LOCAL_NETWORK_PERMISSION)
        activity.state.link = syntheticLink
        activity.testPairing(save = true)
        assertTrue(shows("Checking Mac"))
        assertFalse(activity.state.wifiPermissionNeeded)
        assertFalse(activity.getSharedPreferences("chirp", 0).contains("token"))
    }

}
