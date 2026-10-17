package dev.chirp.android

import org.json.JSONObject

sealed interface ServerEvent {
    data class Ready(val debugRetention: Boolean) : ServerEvent
    data class Partial(val seq: Long, val text: String, val stable: String) : ServerEvent
    data class Final(val text: String, val raw: String, val corrected: Boolean) : ServerEvent
    data class Failure(val code: String) : ServerEvent
    data object Unknown : ServerEvent
}

data class Health(val ready: Boolean, val debugRetention: Boolean, val correctionAvailable: Boolean,
                  val correctionLeavesMachine: Boolean, val correctionHost: String?, val engine: String? = null)

object Protocol {
    fun start(correction: Boolean): String = JSONObject().put("type", "start")
        .put("sample_rate", 16000).put("encoding", "pcm_s16le")
        .put("client", "android").put("correction", correction).toString()
    const val STOP = "{\"type\":\"stop\"}"
    const val CANCEL = "{\"type\":\"cancel\"}"
    fun decode(message: String): ServerEvent {
        require(message.length <= 1_000_000) { "Protocol frame too large" }
        val json = JSONObject(message)
        return when (json.getString("type")) {
            "ready" -> ServerEvent.Ready(json.getBoolean("debug_retention"))
            "partial" -> ServerEvent.Partial(json.getLong("seq"), json.getString("text"), json.optString("stable"))
            "final" -> ServerEvent.Final(json.getString("text"), json.getString("raw"), json.getBoolean("corrected"))
            "error" -> ServerEvent.Failure(json.getString("code")) // Never display untrusted server text.
            else -> ServerEvent.Unknown
        }
    }
    fun health(message: String): Health {
        val json = JSONObject(message)
        require(json.getBoolean("ok") && json.has("ready")) { "Authenticated health required" }
        return Health(json.getBoolean("ready"), json.getBoolean("debug_retention"),
            json.optString("correction") == "available", json.optBoolean("correction_leaves_machine"),
            json.optString("correction_host").takeIf { it.isNotBlank() },
            json.optString("engine").takeIf { it.isNotBlank() }?.take(80))
    }
}
