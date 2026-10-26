package dev.chirp.android

import org.json.JSONArray
import org.json.JSONObject

/**
 * Live Notes speaker labels (issue #187): who said what, as Person 1, Person 2… The Mac's server tells voices apart (in its
 * memory, with saved voices kept only in the server library); this file holds what the phone keeps of it: each segment's turns and the note's roster of people,
 * with their names and merges. A port of the Mac's `SpeakerRoster`/`SpeakerTurn`. Never logged.
 */

/** One turn as the server sent it: its slot in the note (arbitrary, never shown) and seconds from the segment's start. */
data class ServerTurn(val speaker: Int, val start: Double, val text: String, val raw: String,
                               val approximate: Boolean = false, val keptOriginal: Boolean = false)

/** A recognised slot and its server voice's public metadata. */
data class ServerVoiceMatch(val speaker: Int, val voice: String, val name: String)

/** `final.speakers`: turns, recognition, or a fixed error code. */
data class SpeakersResult(val generation: String?, val turns: List<ServerTurn>, val error: String? = null, val matches: List<ServerVoiceMatch> = emptyList()) {
    companion object {
        const val MAX_TURNS = 400
        const val MAX_SLOT = 63

        /** Lenient: anything malformed is no labels, never a failed segment. */
        fun decode(json: JSONObject): SpeakersResult? = try {
            val error = json.optString("error").takeIf { json.has("error") && it.matches(Regex("[a-z_]{1,32}")) }
            if (error != null) SpeakersResult(null, emptyList(), error) else {
                val generation = json.getString("generation").also { require(it.length in 1..64) }
                val list = json.getJSONArray("turns")
                require(list.length() <= MAX_TURNS)
                SpeakersResult(generation, (0 until list.length()).map { i ->
                    val t = list.getJSONObject(i)
                    ServerTurn(t.getInt("speaker").also { require(it in 0..MAX_SLOT) }, t.getDouble("start").coerceAtLeast(0.0),
                        t.getString("text"), t.optString("raw", t.getString("text")), t.optBoolean("approximate"), t.optBoolean("kept_original"))
                }, matches = decodeMatches(json))
            }
        } catch (_: Exception) { null }
        /** A bad match cannot discard valid transcript turns. Drop every conflicting entry. */
        private fun decodeMatches(json: JSONObject): List<ServerVoiceMatch> {
            val array = json.optJSONArray("matches") ?: return emptyList()
            if (array.length() > 64) return emptyList()
            val matches = (0 until array.length()).mapNotNull { i ->
                val item = array.optJSONObject(i) ?: return@mapNotNull null
                val slot = item.opt("speaker")
                val voice = item.opt("voice") as? String ?: return@mapNotNull null
                val name = item.opt("name") as? String ?: return@mapNotNull null
                if (slot !is Int || slot !in 0..MAX_SLOT || !VOICE_ID.matches(voice) || !validVoiceName(name)) null
                else ServerVoiceMatch(slot, voice, name)
            }
            return matches.filter { m -> matches.count { it.speaker == m.speaker } == 1 && matches.count { it.voice == m.voice } == 1 }
        }

    }
}

/** One person's stretch of a segment's text. [start] is in note seconds (the clock of [NotesSegment.offset]). */
internal data class SpeakerTurn(val person: Int, val start: Double, val text: String, val raw: String = text,
                                val approximate: Boolean = false, val keptOriginal: Boolean = false, val overridePerson: Int? = null) {
    val effectivePerson get() = overridePerson ?: person
    fun toJson(): JSONObject = JSONObject().put("person", person).put("start", start).put("text", text).put("raw", raw)
        .apply { if (approximate) put("approximate", true); if (keptOriginal) put("kept", true); overridePerson?.let { put("overridePerson", it) } }

    companion object {
        fun fromJson(json: JSONObject) = SpeakerTurn(json.getInt("person"), json.getDouble("start"), json.getString("text"),
            json.optString("raw", json.getString("text")), json.optBoolean("approximate"), json.optBoolean("kept"), json.optInt("overridePerson").takeIf { it > 0 })
    }
}

/**
 * The people of one note, numbered by first appearance: the first server slot that speaks becomes Person 1. Names and
 * merges are the user's and are saved with the note. Which slot is which person is memory only: a server that lost its
 * state for this note (a restart) says so with a new generation, and its slots then mean new people.
 */
internal class SpeakerRoster {
    class Person(val id: Int, var name: String? = null, var mergedInto: Int? = null) {
        var recognized: ServerVoiceMatch? = null
        val rejected = mutableSetOf<String>()
        var manuallyNamed = false
    }

    private val list = mutableListOf<Person>()
    val people: List<Person> get() = list
    private val slots = HashMap<Int, Int>()
    private var generation: String? = null

    /** The person a server slot speaks as (numbering a new one on first sight); stored in turns, so a merge can be undone. */
    fun id(slot: Int, generation: String?): Int {
        if (generation != this.generation) { slots.clear(); this.generation = generation }
        return slots.getOrPut(slot) { addPerson() }
    }

    fun source(id: Int, session: String): SpeakerVoiceSource? {
        val target = resolve(id)
        val slot = slots.entries.firstOrNull { it.value == target }?.key
            ?: slots.entries.firstOrNull { resolve(it.value) == target }?.key ?: return null
        return generation?.let { SpeakerVoiceSource(session, it, slot) }
    }

    fun recognize(match: ServerVoiceMatch): Int? {
        val id = slots[match.speaker] ?: return null
        val p = person(id) ?: return null
        if (p.mergedInto != null || p.manuallyNamed || match.voice in p.rejected ||
            (p.name != null && p.recognized == null) || slots.values.any { it != id && person(it)?.recognized?.voice == match.voice }) return null
        p.recognized = match
        p.name = match.name
        return id
    }

    fun reject(id: Int) {
        val p = person(resolve(id)) ?: return
        p.recognized?.let { p.rejected += it.voice }
        p.recognized = null; p.name = null; p.manuallyNamed = false
    }

    fun addPerson(): Int { list += Person(list.size + 1); return list.size }

    fun person(id: Int): Person? = list.getOrNull(id - 1)

    /** Follows merges to the person who stands for [id] now. */
    fun resolve(id: Int): Int {
        var current = id
        val seen = HashSet<Int>()
        while (seen.add(current)) current = person(current)?.mergedInto ?: return current
        return current
    }

    /** The one name used everywhere: the transcript, the export and what structuring reads. */
    fun displayName(id: Int): String {
        val target = resolve(id)
        return person(target)?.name?.trim()?.takeIf { it.isNotEmpty() } ?: "Person $target"
    }

    /** A stable colour for [id] (after merges). */
    fun colorIndex(id: Int) = (resolve(id) - 1).mod(PALETTE)

    /** A name for the note; blank goes back to "Person N". */
    fun rename(id: Int, name: String?) {
        val person = person(resolve(id)) ?: return
        person.manuallyNamed = true; person.recognized = null
        person.name = name?.trim()?.take(MAX_NAME)?.takeIf { it.isNotEmpty() }
    }

    /** [id] becomes [target]: its turns resolve to the target; [separate] undoes it. */
    fun merge(id: Int, target: Int) {
        val from = resolve(id); val to = resolve(target)
        if (from == to || person(from) == null || person(to) == null) return
        person(from)!!.mergedInto = to
    }

    fun separate(id: Int) { person(id)?.mergedInto = null }

    /** People still standing with no name of their own yet: who "Who was speaking?" asks about. */
    val unnamed get() = list.filter { it.mergedInto == null && it.name.isNullOrBlank() }.map { it.id }

    /** The people merged straight into [id], for "Separate". */
    fun merged(into: Int) = list.filter { it.mergedInto == into }.map { it.id }

    /** People still standing (not merged away), in order. */
    val active get() = list.filter { it.mergedInto == null }.map { it.id }

    fun toJson(): JSONArray = JSONArray().apply {
        list.forEach { p -> put(JSONObject().put("id", p.id).apply { p.name?.let { put("name", it) }; p.mergedInto?.let { put("merged", it) } }) }
    }

    companion object {
        /** Colours cycle through this many (the palette lives in the UI). */
        const val PALETTE = 8
        const val MAX_NAME = 60

        fun fromJson(array: JSONArray?) = SpeakerRoster().apply {
            if (array != null) for (i in 0 until array.length()) array.getJSONObject(i).let { p ->
                list += Person(i + 1, p.optString("name").takeIf { p.has("name") }, p.optInt("merged").takeIf { p.has("merged") && it in 1..array.length() })
            }
        }
    }
}
