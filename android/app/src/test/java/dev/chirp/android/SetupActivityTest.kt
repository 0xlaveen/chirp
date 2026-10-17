package dev.chirp.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
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

    @Test fun `scan feeds validated pairing into masked field without saving credentials`() {
        scan(); assertEquals(1, activity.scans); assertTrue(activity.state.scanning)
        activity.received(syntheticLink)
        assertFalse(activity.state.scanning); assertEquals(syntheticLink, activity.state.link)
        assertTrue(shows("Pairing link received — test to save"))
        val parsed = Pairing.parse(activity.state.link)
        assertEquals("https://mac.example.test/chirp/v1/health", parsed.endpoint("v1/health").toString())
        assertEquals("synthetic+token=", parsed.token)
        assertFalse(activity.state.checking)
        assertFalse(activity.getSharedPreferences("chirp", 0).contains("token"))
    }
    @Test fun `scanner rejects missing malformed non pairing and insecure payloads`() {
        listOf(null, "", "https://example.test", "chirp://pair?url=http://mac.example.test&token=synthetic",
            "chirp://pair?url=https://mac.example.test&token=a&token=b").forEach { value ->
            scan(); activity.received(value)
            assertEquals("", activity.state.link); assertTrue(shows("Invalid Chirp pairing link"))
            assertFalse(activity.state.scanning)
        }
    }
    @Test fun `cancel and scanner failure leave paste available and preserve field`() {
        activity.state.link = syntheticLink
        scan(); activity.cancelled()
        assertFalse(activity.state.scanning); assertTrue(shows("Scan cancelled")); assertEquals(syntheticLink, activity.state.link)
        scan(); activity.failed()
        assertFalse(activity.state.scanning); assertTrue(shows("check Google Play services")); assertEquals(syntheticLink, activity.state.link)
    }
    @Test fun `deep links share parse feed path and clear credential intent`() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink))
        controller.newIntent(intent)
        assertNull(intent.data); assertEquals(syntheticLink, activity.state.link)
        assertTrue(shows("Pairing link received — test to save"))
        val invalid = Intent(Intent.ACTION_VIEW, Uri.parse("chirp://pair?url=http://mac.example.test&token=synthetic"))
        controller.newIntent(invalid)
        assertNull(invalid.data); assertTrue(shows("Invalid Chirp pairing link"))
        assertEquals(syntheticLink, activity.state.link)
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
