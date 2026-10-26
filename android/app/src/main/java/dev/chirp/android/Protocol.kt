package dev.chirp.android

import org.json.JSONObject

sealed interface ServerEvent {
    data class Ready(val debugRetention: Boolean) : ServerEvent
    data class Partial(val seq: Long, val text: String, val stable: String) : ServerEvent
    data class Correcting(val seq: Long, val raw: String, val profile: String) : ServerEvent
    data class Final(val text: String, val raw: String, val corrected: Boolean, val correctionError: String? = null,
                     /** Live Notes speaker labels, when `start` asked for them (`speakers.session`). */
                     val speakers: SpeakersResult? = null) : ServerEvent
    data class Failure(val code: String) : ServerEvent
    data object Unknown : ServerEvent
}

data class Health(val ready: Boolean, val debugRetention: Boolean, val correctionAvailable: Boolean,
                  val correctionLeavesMachine: Boolean, val correctionHost: String?, val engine: String? = null,
                  val correctionProfiles: List<CorrectionProfile> = emptyList(),
                  val notesStructure: Boolean = false, val notesReorganize: Boolean = false, val notesCorrection: Boolean = false,
                  val notesEdit: Boolean = false,
                  /** The server labels speakers (`start.speakers`), and its speaker model's state (`ready`, `not_downloaded`…). */
                  val notesSpeakers: Boolean = false, val speakersModel: String? = null)

object Protocol {
    fun start(correction: Boolean, profile: String = "default", instructions: String = "", prompt: String? = null,
              speakers: String? = null, learned: LearnedPayload? = null): String {
        require(CleanupStyles.validId(profile))
        require(speakers == null || SPEAKER_SESSION.matches(speakers))
        require(CleanupStyles.characterCount(instructions) <= CleanupStyles.MAX_INSTRUCTIONS)
        require(prompt == null || CleanupStyles.characterCount(prompt) <= CleanupStyles.MAX_PROMPT)
        return JSONObject().put("type", "start")
        .put("sample_rate", 16000).put("encoding", "pcm_s16le")
        .put("client", "android").put("correction", correction)
        .put("correction_profile", profile).put("correction_instructions", if (profile == "custom") instructions else "")
        .apply { if (prompt != null) put("correction_prompt", prompt) }
        .apply { if (learned != null && !learned.isEmpty) put("learned", learned.wire()) }
        .apply { if (speakers != null) put("speakers", JSONObject().put("session", speakers)) }.toString()
    }
    /** A note's random speaker-session id, as the server accepts it. */
    val SPEAKER_SESSION = Regex("[A-Za-z0-9_-]{16,64}")
    const val STOP = "{\"type\":\"stop\"}"
    const val CANCEL = "{\"type\":\"cancel\"}"
    fun decode(message: String): ServerEvent {
        require(message.length <= 1_000_000) { "Protocol frame too large" }
        val json = JSONObject(message)
        return when (json.getString("type")) {
            "ready" -> ServerEvent.Ready(json.getBoolean("debug_retention"))
            "partial" -> ServerEvent.Partial(json.getLong("seq"), json.getString("text"), json.optString("stable"))
            "correcting" -> ServerEvent.Correcting(json.getLong("seq"), json.getString("raw"), json.getString("profile"))
            "final" -> ServerEvent.Final(json.getString("text"), json.getString("raw"), json.getBoolean("corrected"),
                json.optString("correction_error").takeIf { it.isNotBlank() && it != "null" },
                json.optJSONObject("speakers")?.let(SpeakersResult::decode))
            "error" -> ServerEvent.Failure(json.getString("code")) // Never display untrusted server text.
            else -> ServerEvent.Unknown
        }
    }
    fun profiles(message: String): List<CorrectionProfile> {
        require(message.length <= 512000) { "Profiles too large" }
        val array = JSONObject(message).getJSONArray("profiles")
        return buildList {
            for (i in 0 until array.length()) {
                val item = array.getJSONObject(i)
                val id = item.getString("id")
                require(CleanupStyles.validId(id)) { "Invalid profile" }
                val prompt = item.getString("prompt")
                val maximum = item.getInt("max_prompt_chars")
                require(maximum in 1..CleanupStyles.MAX_PROMPT && CleanupStyles.characterCount(prompt) <= maximum) { "Invalid prompt limit" }
                if (none { it.id == id }) add(CorrectionProfile(id, item.getString("name").take(80),
                    item.getString("description").take(300), item.getBoolean("rewrites"), prompt, maximum))
            }
        }
    }
    fun health(message: String): Health {
        val json = JSONObject(message)
        require(json.getBoolean("ok") && json.has("ready")) { "Authenticated health required" }
        return Health(json.getBoolean("ready"), json.getBoolean("debug_retention"),
            json.optString("correction") == "available", json.optBoolean("correction_leaves_machine"),
            json.optString("correction_host").takeIf { it.isNotBlank() && it != "null" },
            json.optString("engine").takeIf { it.isNotBlank() }?.take(80),
            buildList {
                val profiles = json.optJSONArray("correction_profiles")
                if (profiles != null) for (i in 0 until profiles.length()) {
                    val item = profiles.optJSONObject(i) ?: continue
                    val id = item.optString("id")
                    if (CleanupStyles.validId(id) && none { it.id == id }) add(CorrectionProfile(id,
                        item.optString("name", id).take(80), item.optString("description").take(300), item.optBoolean("rewrites")))
                }
            }, json.optBoolean("notes_structure"), json.optBoolean("notes_reorganize"), json.optBoolean("notes_correction"),
            json.optBoolean("notes_edit"), json.optBoolean("notes_speakers"),
            json.optJSONObject("speakers_model")?.optString("state")?.takeIf { it.matches(Regex("[a-z_]{1,32}")) })
    }
}
