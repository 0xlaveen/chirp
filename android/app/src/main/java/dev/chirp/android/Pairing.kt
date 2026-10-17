package dev.chirp.android

import java.net.URI
import java.net.URLDecoder
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

// Deliberately not a data class: toString must never expose a credential.
class Pairing(val base: HttpUrl, val token: String) {
    override fun toString() = "Pairing(<redacted>)"
    fun endpoint(path: String): HttpUrl = base.newBuilder()
        .addPathSegments(path.trimStart('/')).build()

    companion object {
        fun parse(link: String): Pairing {
            require(link.length in 1..16384) { "Paste a Chirp pairing link" }
            val uri = try { URI(link.trim()) } catch (_: Exception) { error("Invalid pairing link") }
            require(uri.scheme == "chirp" && uri.host == "pair" && uri.rawFragment == null &&
                uri.rawUserInfo == null && uri.port == -1 && uri.path.orEmpty().isEmpty()) { "Invalid pairing link" }
            val pairs = try {
                uri.rawQuery.orEmpty().split('&').map { item ->
                    val parts = item.split('=', limit = 2)
                    require(parts.size == 2)
                    URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts[1], "UTF-8")
                }
            } catch (_: Exception) { error("Invalid pairing link") }
            require(pairs.map { it.first }.toSet() == setOf("url", "token") && pairs.size == 2) { "Link needs url and token" }
            return from(pairs.toMap().getValue("url"), pairs.toMap().getValue("token"))
        }

        fun from(url: String, token: String): Pairing {
            val base = try { url.toHttpUrl() } catch (_: Exception) { error("Invalid server address") }
            require(allowedServer(base) && base.username.isEmpty() && base.password.isEmpty() &&
                base.query == null && base.fragment == null) { "Server must use HTTPS without credentials or query" }
            require(token.length in 1..4096 && token.all { it.code in 33..126 }) { "Invalid pairing token" }
            val normalized = base.newBuilder().apply {
                if (!base.encodedPath.endsWith('/')) addPathSegment("")
            }.build()
            return Pairing(normalized, token)
        }
    }
}
