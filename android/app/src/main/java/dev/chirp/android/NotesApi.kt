package dev.chirp.android

import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * `POST /v1/notes/structure`. Only `transcript`, `outline` and `final` go on the wire; the rest stays on the phone so a
 * late answer is matched to the window and tail it was asked for. Never logged.
 */
internal data class NotesStructureRequest(val transcript: String, val outline: List<String> = emptyList(), val final: Boolean = false,
    val windowEnd: Int = 0, val version: Int = 0, val windowGeneration: Int = 0, val documentId: Long? = null) {
    fun json(): String = JSONObject().put("transcript", transcript).put("outline", JSONArray(outline)).put("final", final).toString()
}

/** `structured:false` fails closed: no Markdown, and `error` says why (`timeout`, `http`, `rejected`, `busy`…). */
internal data class NotesStructureResponse(val markdown: String?, val structured: Boolean, val error: String? = null, val reason: String? = null) {
    val failureLabel get() = NotesFailure.label(error, reason)
    companion object {
        fun failed(code: String) = NotesStructureResponse(null, false, code)
        fun decode(body: String) = JSONObject(body).let {
            val markdown = it.optString("markdown").takeIf { _ -> it.has("markdown") && !it.isNull("markdown") }
            NotesStructureResponse(markdown, markdown != null && it.optBoolean("structured"), it.text("error"), it.text("reason"))
        }
    }
}

/** `POST /v1/notes/reorganize`: the trailing sections; `version` and `[start, end)` stay on the phone. Never logged. */
internal data class NotesReorganizeRequest(val notes: String, val outline: List<String> = emptyList(), val final: Boolean = false,
    val version: Int = 0, val start: Int = 0, val end: Int = 0, val documentId: Long? = null) {
    fun json(): String = JSONObject().put("notes", notes).put("outline", JSONArray(outline)).put("final", final).toString()
}

/** `changed:false` means already tidy; `error:"preempted"` means a segment clean-up took the model, which is not a failure. */
internal data class NotesReorganizeResponse(val markdown: String?, val reorganized: Boolean, val changed: Boolean = true,
    val error: String? = null, val reason: String? = null) {
    val failureLabel get() = NotesFailure.label(error, reason)
    val preempted get() = !reorganized && error == "preempted"
    companion object {
        fun failed(code: String) = NotesReorganizeResponse(null, false, false, code)
        fun decode(body: String) = JSONObject(body).let {
            val markdown = it.optString("markdown").takeIf { _ -> it.has("markdown") && !it.isNull("markdown") }
            NotesReorganizeResponse(markdown, markdown != null && it.optBoolean("reorganized"), markdown != null && it.optBoolean("changed"),
                it.text("error"), it.text("reason"))
        }
    }
}

private fun JSONObject.text(key: String) = if (has(key) && !isNull(key)) optString(key) else null

internal object NotesFailure {
    /** A guard name as the server sends it (`novel_name`), else null: it is shown, so it is never free text. */
    fun guardName(reason: String?) = reason?.takeIf { it.length in 1..40 && it.all { c -> c == '_' || c in 'a'..'z' || c in '0'..'9' } }
    fun label(error: String?, reason: String?): String {
        val code = guardName(error) ?: "http"
        return guardName(reason)?.let { "$code: $it" } ?: code
    }
}

/** Why a notes call got no answer to use. */
internal class NotesHttpError(val status: Int) : IOException("Notes HTTP $status") {
    /** 409 `notes_off`: clean-up is off on the server. 404/405: an older server without the endpoint. */
    val off get() = status == 409
    val unsupported get() = status == 404 || status == 405
    val code get() = when (status) { 401 -> "auth"; 404, 405 -> "unsupported"; 409 -> "notes_off"; 503 -> "busy"; else -> "http" }
}

/** The two notes calls. Blocking: callers run them off the main thread. Logs nothing. */
internal interface NotesApi {
    fun structure(request: NotesStructureRequest): NotesStructureResponse
    fun reorganize(request: NotesReorganizeRequest): NotesReorganizeResponse
}

internal class HttpNotesApi(client: OkHttpClient, private val pairing: Pairing) : NotesApi {
    /** The server's structure timeout (30 s) and reorganize timeout (45 s), plus a margin. */
    private val structureClient = client.newBuilder().readTimeout(35, TimeUnit.SECONDS).callTimeout(35, TimeUnit.SECONDS).build()
    private val reorganizeClient = client.newBuilder().readTimeout(50, TimeUnit.SECONDS).callTimeout(50, TimeUnit.SECONDS).build()

    override fun structure(request: NotesStructureRequest) = NotesStructureResponse.decode(post(structureClient, "v1/notes/structure", request.json()))
    override fun reorganize(request: NotesReorganizeRequest) = NotesReorganizeResponse.decode(post(reorganizeClient, "v1/notes/reorganize", request.json()))

    private fun post(client: OkHttpClient, path: String, body: String): String {
        val request = Request.Builder().url(pairing.endpoint(path)).header("Authorization", "Bearer ${pairing.token}")
            .post(body.toRequestBody("application/json".toMediaType())).build()
        client.newCall(request).execute().use { response ->
            if (response.code != 200) throw NotesHttpError(response.code)
            val source = response.body.source()
            source.request(MAX_BODY + 1)
            if (source.buffer.size > MAX_BODY) throw IOException("Notes answer too large")
            return source.readUtf8()
        }
    }

    companion object {
        const val MAX_BODY = 262144L
        /** A client timeout counts as the server's `timeout`; anything else as `http`. */
        fun code(error: Throwable) = when (error) {
            is NotesHttpError -> error.code
            is InterruptedIOException -> "timeout"
            else -> "http"
        }
    }
}
