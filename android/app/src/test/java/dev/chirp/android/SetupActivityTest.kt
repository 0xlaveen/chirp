package dev.chirp.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
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
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup)
        (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()
    private val views get() = descendants(activity.window.decorView)
    private val link get() = views.filterIsInstance<EditText>().single { it.hint.toString().startsWith("chirp://") }
    private val scan get() = views.filterIsInstance<Button>().single { it.text.toString() == "Scan pairing QR" }
    private fun shows(text: String) = views.filterIsInstance<TextView>().any { it.text.toString().contains(text) }
    @Before fun setUp() {
        controller = Robolectric.buildActivity(TestSetup::class.java).setup()
        activity = controller.get()
    }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    @Test fun `scan feeds validated pairing into masked field without saving credentials`() {
        scan.performClick(); assertEquals(1, activity.scans); assertFalse(scan.isEnabled)
        activity.received(syntheticLink)
        assertTrue(scan.isEnabled); assertEquals(syntheticLink, link.text.toString())
        assertTrue(shows("Pairing link received — test to save"))
        val parsed = Pairing.parse(link.text.toString())
        assertEquals("https://mac.example.test/chirp/v1/health", parsed.endpoint("v1/health").toString())
        assertEquals("synthetic+token=", parsed.token)
        assertFalse(link.isSaveEnabled)
        assertFalse(activity.getSharedPreferences("chirp", 0).contains("token"))
    }
    @Test fun `scanner rejects missing malformed non pairing and insecure payloads`() {
        listOf(null, "", "https://example.test", "chirp://pair?url=http://mac.example.test&token=synthetic",
            "chirp://pair?url=https://mac.example.test&token=a&token=b").forEach { value ->
            scan.performClick(); activity.received(value)
            assertEquals("", link.text.toString()); assertTrue(shows("Invalid Chirp pairing link"))
            assertTrue(scan.isEnabled)
        }
    }
    @Test fun `cancel and scanner failure leave paste available and preserve field`() {
        link.setText(syntheticLink)
        scan.performClick(); activity.cancelled()
        assertTrue(scan.isEnabled); assertTrue(shows("Scan cancelled")); assertEquals(syntheticLink, link.text.toString())
        scan.performClick(); activity.failed()
        assertTrue(scan.isEnabled); assertTrue(shows("check Google Play services")); assertEquals(syntheticLink, link.text.toString())
    }
    @Test fun `deep links share parse feed path and clear credential intent`() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink))
        controller.newIntent(intent)
        assertNull(intent.data); assertEquals(syntheticLink, link.text.toString())
        assertTrue(shows("Pairing link received — test to save"))
        val invalid = Intent(Intent.ACTION_VIEW, Uri.parse("chirp://pair?url=http://mac.example.test&token=synthetic"))
        controller.newIntent(invalid)
        assertNull(invalid.data); assertTrue(shows("Invalid Chirp pairing link"))
        assertEquals(syntheticLink, link.text.toString())
    }
    @Test fun `late scan result cannot feed a destroyed activity`() {
        scan.performClick()
        controller.pause().stop().destroy()
        activity.received(syntheticLink)
        assertEquals("", link.text.toString())
    }
    @Test fun `app does not request camera permission`() {
        val info = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
        assertFalse(info.requestedPermissions.orEmpty().contains(Manifest.permission.CAMERA))
    }
}
