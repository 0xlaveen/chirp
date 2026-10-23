package dev.chirp.android

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

internal class UpdateInfo(val versionCode: Long, val versionName: String, val file: HttpUrl, val sha256: String, val size: Long)

/** Self-update from the paired Mac's tailnet-hosted APK (`/chirp-apk/latest.json`). The host is always the pairing's own;
 * the manifest only names a file inside that directory, never another URL. No bearer token is sent to this static path. */
internal object AppUpdates {
    const val MAX_APK = 200L shl 20
    private const val MAX_MANIFEST = 4096L
    private val FILE = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\.apk")
    private val SHA = Regex("[0-9a-f]{64}")

    /** `https://<paired host>/chirp-apk/`, or null unless the pairing points at a tailnet host. */
    fun base(pairing: Pairing): HttpUrl? =
        if (TailscaleControl.routes(pairing.base)) pairing.base.newBuilder().encodedPath("/chirp-apk/").build() else null

    fun parse(json: String, base: HttpUrl): UpdateInfo {
        val manifest = try { JSONObject(json) } catch (_: Exception) { throw IOException("Invalid update manifest") }
        val file = manifest.optString("file")
        val sha = manifest.optString("sha256")
        val code = manifest.optLong("version_code", -1)
        val size = manifest.optLong("size", -1)
        val name = manifest.optString("version_name")
        if (!FILE.matches(file) || !SHA.matches(sha) || code <= 0 || size !in 1..MAX_APK || name.isEmpty() || name.length > 32) {
            throw IOException("Invalid update manifest")
        }
        return UpdateInfo(code, name, base.newBuilder().addPathSegment(file).build(), sha, size)
    }

    /** The newest hosted version when it is newer than [installed]; null when up to date. */
    fun check(client: OkHttpClient, base: HttpUrl, installed: Long): UpdateInfo? {
        val request = Request.Builder().url(base.newBuilder().addPathSegment("latest.json").build()).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Updates unavailable")
            val source = response.body.source()
            source.request(MAX_MANIFEST + 1)
            if (source.buffer.size > MAX_MANIFEST) throw IOException("Invalid update manifest")
            val info = parse(source.readUtf8(), base)
            return info.takeIf { it.versionCode > installed }
        }
    }

    /** Streams to [dest], bounded by the manifest size, and keeps it only if length and SHA-256 match. */
    fun download(client: OkHttpClient, info: UpdateInfo, dest: File) {
        val request = Request.Builder().url(info.file).build()
        val digest = MessageDigest.getInstance("SHA-256")
        dest.parentFile?.mkdirs()
        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw IOException("Update unavailable")
                var total = 0L
                response.body.source().use { source ->
                    dest.outputStream().use { out ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val read = source.read(buffer)
                            if (read < 0) break
                            total += read
                            if (total > info.size) throw IOException("Update larger than announced")
                            digest.update(buffer, 0, read); out.write(buffer, 0, read)
                        }
                    }
                }
                if (total != info.size || digest.digest().joinToString("") { "%02x".format(it) } != info.sha256) {
                    throw IOException("Update failed verification")
                }
            }
        } catch (error: Exception) { dest.delete(); throw error }
    }
}
