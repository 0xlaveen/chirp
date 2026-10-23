package dev.chirp.android

import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class UpdateControllerTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()
    private val requested = mutableListOf<String>()
    private val manifest = """{"version_code":12,"version_name":"0.6.2","file":"chirp-0.6.2.apk","sha256":"${"a".repeat(64)}","size":1000}"""
    private fun controller(url: String?, installed: Long = 11, body: String = manifest): UpdateController {
        val client = okhttp3.OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            requested += chain.request().url.toString()
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }).build()
        return UpdateController(context, CoroutineScope(Dispatchers.Unconfined), client,
            pairing = { url?.let { Pairing.from(it, "synthetic") } }, installed = { installed })
    }
    private fun settle(controller: UpdateController, done: (UpdateStatus) -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000
        while (!done(controller.status) && System.nanoTime() < deadline) { shadowOf(android.os.Looper.getMainLooper()).idle(); Thread.sleep(10) }
    }

    @Test fun `manual check asks only the paired tailnet host and offers a newer build`() {
        val updates = controller("https://mac.tail1234.ts.net/chirp"); updates.check()
        settle(updates) { it is UpdateStatus.Available }
        assertEquals("0.6.2", (updates.status as UpdateStatus.Available).info.versionName)
        assertEquals(listOf("https://mac.tail1234.ts.net/chirp-apk/latest.json"), requested)
    }
    @Test fun `up to date reports current manually and stays silent automatically`() {
        val manual = controller("https://mac.tail1234.ts.net/chirp", installed = 12); manual.check()
        settle(manual) { it is UpdateStatus.Current }
        assertEquals(UpdateStatus.Current, manual.status)
        val automatic = controller("https://mac.tail1234.ts.net/chirp", installed = 12); automatic.check(manual = false)
        settle(automatic) { requested.size == 2 }; Thread.sleep(50)
        assertEquals(UpdateStatus.Idle, automatic.status)
    }
    @Test fun `non tailnet or missing pairing never touches the network`() {
        listOf("https://mac.example.test/chirp", null).forEach { url ->
            val updates = controller(url); updates.check()
            settle(updates) { it is UpdateStatus.Failed }
            assertTrue(updates.status is UpdateStatus.Failed)
        }
        assertTrue(requested.isEmpty())
    }
    @Test fun `install asks for permission to install before downloading`() {
        val updates = controller("https://mac.tail1234.ts.net/chirp")
        shadowOf(context.packageManager).setCanRequestPackageInstalls(false)
        updates.install(UpdateInfo(12, "0.6.2", "https://mac.tail1234.ts.net/chirp-apk/chirp-0.6.2.apk".let { okhttp3.HttpUrl.Companion.run { it.toHttpUrl() } }, "a".repeat(64), 1000))
        assertEquals(UpdateStatus.NeedsPermission, updates.status)
        assertTrue(requested.isEmpty())
    }
}
