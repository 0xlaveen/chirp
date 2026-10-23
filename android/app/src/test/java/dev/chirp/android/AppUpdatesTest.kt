package dev.chirp.android

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppUpdatesTest {
    @get:Rule val temp = TemporaryFolder()
    private val apk = ByteArray(5000) { (it % 251).toByte() }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun manifest(code: Int = 12, file: String = "chirp-0.6.2.apk", sha: String = sha(apk), size: Int = apk.size) =
        """{"version_code":$code,"version_name":"0.6.2","file":"$file","sha256":"$sha","size":$size}"""
    private val base = "https://mac.tail1234.ts.net/chirp-apk/".toHttpUrl()
    private fun withServer(test: (MockWebServer, okhttp3.HttpUrl) -> Unit) = MockWebServer().use { server ->
        server.start(); test(server, server.url("/chirp-apk/"))
    }
    private fun info(url: okhttp3.HttpUrl, sha: String = sha(apk), size: Long = apk.size.toLong()) = UpdateInfo(12, "0.6.2", url, sha, size)

    @Test fun `update base is the paired tailnet host with the update path`() {
        assertEquals(base, AppUpdates.base(Pairing.from("https://mac.tail1234.ts.net/chirp", "synthetic")))
        assertEquals("https://mac.tail1234.ts.net:8443/chirp-apk/",
            AppUpdates.base(Pairing.from("https://mac.tail1234.ts.net:8443/chirp/", "synthetic")).toString())
        assertEquals("https://100.101.102.103/chirp-apk/", AppUpdates.base(Pairing.from("https://100.101.102.103/chirp", "synthetic")).toString())
    }
    @Test fun `non tailnet pairings get no update host`() {
        listOf("https://mac.example.test/chirp", "https://192.168.1.20/chirp", "https://evil.ts.net.example.test/chirp").forEach {
            assertNull(it, AppUpdates.base(Pairing.from(it, "synthetic")))
        }
    }
    @Test fun `manifest resolves only a file inside the update directory`() {
        val info = AppUpdates.parse(manifest(), base)
        assertEquals("https://mac.tail1234.ts.net/chirp-apk/chirp-0.6.2.apk", info.file.toString())
        assertEquals(12L, info.versionCode); assertEquals("0.6.2", info.versionName)
    }
    @Test fun `manifest naming another host path or malformed field is rejected`() {
        listOf(
            manifest(file = "https://evil.example.test/a.apk"), manifest(file = "//evil.example.test/a.apk"), manifest(file = "../a.apk"),
            manifest(file = "sub/a.apk"), manifest(file = "a.txt"), manifest(file = ".apk"), manifest(sha = "ABC"), manifest(code = 0),
            manifest(size = 0), manifest(size = Int.MAX_VALUE), "{}", "nope", "[]",
        ).forEach { json -> assertThrows(json, IOException::class.java) { AppUpdates.parse(json, base) } }
    }
    @Test fun `check offers only newer versions and sends no credentials`() = withServer { server, url ->
        server.enqueue(MockResponse().setBody(manifest(code = 12)))
        assertEquals("0.6.2", AppUpdates.check(ChirpNetwork.client(), url, installed = 11)!!.versionName)
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/chirp-apk/latest.json", request.path); assertNull(request.getHeader("Authorization"))
        server.enqueue(MockResponse().setBody(manifest(code = 12)))
        assertNull(AppUpdates.check(ChirpNetwork.client(), url, installed = 12))
        server.enqueue(MockResponse().setBody(manifest(code = 12)))
        assertNull(AppUpdates.check(ChirpNetwork.client(), url, installed = 13))
    }
    @Test fun `check rejects redirects errors and oversized manifests`() = withServer { server, url ->
        server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "https://evil.example.test/latest.json"))
        assertThrows(IOException::class.java) { AppUpdates.check(ChirpNetwork.client(), url, 1) }
        server.enqueue(MockResponse().setResponseCode(404))
        assertThrows(IOException::class.java) { AppUpdates.check(ChirpNetwork.client(), url, 1) }
        server.enqueue(MockResponse().setBody("x".repeat(5000)))
        assertThrows(IOException::class.java) { AppUpdates.check(ChirpNetwork.client(), url, 1) }
    }
    @Test fun `download keeps a verified apk`() = withServer { server, url ->
        server.enqueue(MockResponse().setBody(okio.Buffer().write(apk)))
        val dest = File(temp.root, "u/update.apk")
        AppUpdates.download(ChirpNetwork.client(), info(url.resolve("chirp-0.6.2.apk")!!), dest)
        assertArrayEquals(apk, dest.readBytes())
        assertNull(server.takeRequest(5, TimeUnit.SECONDS)!!.getHeader("Authorization"))
    }
    @Test fun `download deletes files that fail hash size or status`() = withServer { server, url ->
        val file = url.resolve("chirp-0.6.2.apk")!!
        val dest = File(temp.root, "update.apk")
        server.enqueue(MockResponse().setBody(okio.Buffer().write(apk)))
        assertThrows(IOException::class.java) { AppUpdates.download(ChirpNetwork.client(), info(file, sha = "0".repeat(64)), dest) }
        assertFalse(dest.exists())
        server.enqueue(MockResponse().setBody(okio.Buffer().write(apk)))
        assertThrows(IOException::class.java) { AppUpdates.download(ChirpNetwork.client(), info(file, size = 100), dest) }
        assertFalse(dest.exists())
        server.enqueue(MockResponse().setBody(okio.Buffer().write(apk.copyOf(10))))
        assertThrows(IOException::class.java) { AppUpdates.download(ChirpNetwork.client(), info(file), dest) }
        assertFalse(dest.exists())
        server.enqueue(MockResponse().setResponseCode(500))
        assertThrows(IOException::class.java) { AppUpdates.download(ChirpNetwork.client(), info(file), dest) }
        assertFalse(dest.exists())
    }
}
