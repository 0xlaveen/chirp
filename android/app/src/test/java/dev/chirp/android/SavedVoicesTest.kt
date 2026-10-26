package dev.chirp.android

import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private val savedVoice = SavedVoice("0123456789abcdef", "Maya", 46.0, "2026-10-12T00:00:00Z", "2026-10-20T00:00:00Z", true)
private val library = SavedVoices(true, "synthetic", listOf(savedVoice))
private val voicesMac = notesMac.copy(notesSpeakers = true, speakersModel = "ready", speakerVoices = true,
    speakersVoices = SpeakersVoicesHealth(true, 1, "synthetic"))
private fun match() = ServerVoiceMatch(0, savedVoice.id, savedVoice.name)

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class SavedVoicesTest {
    @Test fun `capability accepts both health shapes and old servers stay unsupported`() {
        for (capability in listOf("\"speaker_voices\":true", "\"capabilities\":[\"speaker_voices\"]")) {
            val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,$capability,"speakers_voices":{"enabled":false,"count":2,"model":"synthetic"}}""")
            assertTrue(health.speakerVoices); assertEquals(false, health.speakersVoices?.enabled)
            val store = SettingsStore(RuntimeEnvironment.getApplication()).apply { this.health = health }
            assertEquals(health, store.health)
        }
        assertFalse(Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""").speakerVoices)
    }

    @Test fun `malformed and conflicting matches leave valid turns intact`() {
        val pairs = listOf(
            """{"speaker":0,"voice":"${savedVoice.id}","name":"Maya"}""",
            """{"speaker":0,"voice":"fedcba9876543210","name":"Sam"}""",
            """{"speaker":1,"voice":"${savedVoice.id}","name":"Maya"}""",
            """{"speaker":2,"voice":"bad","name":"Maya"}""",
            """{"speaker":3,"voice":"1111111111111111","name":"Bad: name"}""",
            """{"speaker":4,"voice":"2222222222222222","name":"Sam"}""")
        val result = SpeakersResult.decode(JSONObject("""{"generation":"g","turns":[{"speaker":0,"start":0,"text":"Synthetic fixture"}],"matches":[${pairs.joinToString(",")},null,17]}"""))!!
        assertEquals(1, result.turns.size); assertEquals(listOf(ServerVoiceMatch(4, "2222222222222222", "Sam")), result.matches)
        assertEquals(1, SpeakersResult.decode(JSONObject("""{"generation":"g","turns":[{"speaker":0,"start":0,"text":"Fixture"}],"matches":"broken"}"""))!!.turns.size)
    }

    @Test fun `auto names reach structuring Not X suppresses only this person and manual names win`() {
        val rig = NotesRig(voicesMac)
        rig.recorder.labelSpeakers = true; rig.recorder.recognizeVoices = true
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("Synthetic fixture", speakers = SpeakersResult("g", listOf(ServerTurn(0, 0.0, "Synthetic fixture", "fixture")), matches = listOf(match())))
        rig.idle()
        val doc = rig.recorder.document
        assertEquals("Maya", doc.roster.displayName(1)); assertNotNull(doc.roster.person(1)?.recognized)
        assertTrue(doc.spoken(doc.segments.first()).startsWith("Maya:"))
        doc.roster.reject(1)
        assertNull(doc.roster.recognize(match())); assertEquals("Person 1", doc.roster.displayName(1))
        assertNull(doc.roster.person(1)?.recognized)
        val roster = SpeakerRoster(); roster.id(0, "g"); roster.rename(1, "Sam")
        assertNull(roster.recognize(match())); assertEquals("Sam", roster.displayName(1))
        roster.id(0, "new-generation")
        assertEquals(2, roster.recognize(match()))
        val restarted = SpeakerRoster()
        restarted.id(0, "first"); assertEquals(1, restarted.recognize(match()))
        restarted.id(0, "restarted"); assertEquals(2, restarted.recognize(match()))
        // Only names and turns persist: no library ids, references or voiceprint fields.
        val persisted = doc.toJson().toString() + doc.exportMarkdown()
        assertFalse(persisted.contains(savedVoice.id)); assertFalse(persisted.contains("embedding")); assertFalse(persisted.contains(rig.recorder.speakerSession))
    }

    @Test fun `naming remembers from the session retries short voices after a segment and shows one notice`() {
        val actions = mutableListOf<VoiceAction>()
        var short = true
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), voicesMac, voices = { action ->
            if (action != null) actions += action
            if (action is VoiceAction.Remember && short) throw VoiceLibraryError("too_short")
            library.copy(voice = if (action is VoiceAction.Remember) savedVoice else null)
        })
        rig.model.refreshVoices(); rig.idle()
        rig.model.recorder.labelSpeakers = true
        rig.record().final("Fixture", speakers = SpeakersResult("g", listOf(ServerTurn(0, 0.0, "Fixture", "fixture")))); rig.idle()
        rig.model.renameSpeakers(mapOf(1 to "Maya")); rig.idle()
        val remember = actions.single() as VoiceAction.Remember
        assertEquals(SpeakerVoiceSource(rig.model.recorder.speakerSession, "g", 0), remember.source)
        assertNull(rig.model.voiceNotice)
        short = false
        rig.model.stop(); rig.wire.final("More fixture", speakers = SpeakersResult("g", listOf(ServerTurn(0, 0.0, "More fixture", "fixture")))); rig.idle()
        assertEquals(2, actions.filterIsInstance<VoiceAction.Remember>().size)
        assertEquals("Maya", rig.model.voiceNotice)
        assertNull(rig.model.message)
        rig.model.acknowledgeVoiceNotice(); assertNull(rig.model.voiceNotice)
        rig.model.updateVoice(1); rig.idle()
        assertEquals(savedVoice.id, (actions.last() as VoiceAction.Remember).voice)
        assertNull(rig.model.voiceNotice)
        rig.model.disableRememberVoices(); rig.idle()
        assertEquals(VoiceAction.Disable(false), actions.last())
    }

    @Test fun `unchecked remember old servers and server disabled never enroll`() {
        for (health in listOf(voicesMac, notesMac)) {
            val actions = mutableListOf<VoiceAction>()
            val rig = NotesModelRig(RuntimeEnvironment.getApplication(), health, voices = { action ->
                if (action != null) actions += action
                library.copy(enabled = false)
            })
            rig.model.recorder.document.roster.id(0, "g")
            rig.model.renameSpeakers(mapOf(1 to "Maya"), remember = emptySet()); rig.idle()
            assertTrue(actions.isEmpty())
            rig.model.renameSpeaker(1, "Sam"); rig.idle()
            assertTrue(actions.isEmpty())
            assertEquals("Sam", rig.model.document.roster.displayName(1))
        }
    }

    @Test fun `voiceprint fields are discarded and never enter note export structuring or preferences`() {
        val digits = "0.917263548102"
        val decoded = SavedVoices.decode("""{"enabled":true,"model":"synthetic","voices":[{"id":"${savedVoice.id}","name":"Maya","seconds":46,"created":"2026-10-12T00:00:00Z","updated":"2026-10-20T00:00:00Z","compatible":true,"embedding":[$digits]}]}""")
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), voicesMac, voices = { decoded })
        rig.model.refreshVoices(); rig.idle()
        rig.model.recorder.document.roster.id(0, "g")
        rig.model.recorder.document.append(NotesSegment(0, 0.0, "Synthetic fixture", turns = listOf(SpeakerTurn(1, 0.0, "Synthetic fixture"))))
        rig.model.renameSpeaker(1, "Maya", remember = false)
        val doc = rig.model.document
        val values = listOf(decoded.toString(), doc.toJson().toString(), doc.exportMarkdown(), doc.nextStructureRequest()!!.transcript,
            RuntimeEnvironment.getApplication().getSharedPreferences(SettingsStore.FILE, 0).all.toString())
        assertTrue(values.none { digits in it || "embedding" in it })
        assertTrue(values.drop(1).none { savedVoice.id in it })
    }

    @Test fun `client authenticates actions bounds responses and maps fixed errors`() {
        MockWebServer().use { server ->
            val certificate = okhttp3.tls.HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
            val serverTls = okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(certificate).build()
            val clientTls = okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.start()
            val paired = Pairing.from(server.url("/").toString(), "synthetic")
            val client = ChirpNetwork.client().newBuilder().sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build()
            try {
                server.enqueue(MockResponse().setBody("""{"enabled":true,"model":"synthetic","voices":[]}"""))
                assertTrue(ChirpNetwork.savedVoices(client, paired).enabled)
                assertEquals("Bearer synthetic", server.takeRequest().getHeader("Authorization"))
                // A library refresh can reuse a socket the server has already retired.
                server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST))
                server.enqueue(MockResponse().setBody("""{"enabled":true,"model":"synthetic","voices":[]}"""))
                assertTrue(ChirpNetwork.savedVoices(client, paired).enabled)
                server.takeRequest(); server.takeRequest()
                val source = SpeakerVoiceSource("0123456789abcdef", "g", 0)
                for (action in listOf(VoiceAction.Remember("Maya", source, savedVoice.id), VoiceAction.Rename(savedVoice.id, "Sam"), VoiceAction.Forget(savedVoice.id), VoiceAction.ForgetAll, VoiceAction.Enable, VoiceAction.Disable(true))) {
                    server.enqueue(MockResponse().setBody("""{"enabled":true,"model":"synthetic","voices":[]}"""))
                    ChirpNetwork.savedVoices(client, paired, action)
                    val request = server.takeRequest()
                    assertEquals("/v1/speakers/voices", request.path)
                    assertEquals(action.json().toString(), request.body.readUtf8())
                }
                val beforeWrite = server.requestCount
                server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AFTER_REQUEST))
                assertThrows(java.io.IOException::class.java) { ChirpNetwork.savedVoices(client, paired, VoiceAction.Remember("Maya", source)) }
                assertEquals(beforeWrite + 1, server.requestCount)
                server.takeRequest()
                for ((status, code) in listOf(404 to "gone", 409 to "too_short", 409 to "disabled", 409 to "full", 404 to "no_voice", 400 to "bad_speakers", 401 to "auth")) {
                    server.enqueue(MockResponse().setResponseCode(status).setBody("""{"code":"$code","message":"private fixture"}"""))
                    val error = assertThrows(VoiceLibraryError::class.java) { ChirpNetwork.savedVoices(client, paired) }
                    assertEquals(code, error.code); assertFalse(error.message!!.contains("private"))
                }
                server.enqueue(MockResponse().setBody("x".repeat(65537)))
                assertThrows(VoiceLibraryError::class.java) { ChirpNetwork.savedVoices(client, paired) }
            } finally { ChirpNetwork.dispose(client) }
        }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SavedVoicesRenderTest {
    @get:Rule val compose = createComposeRule()
    @Test fun `saved voices and recognized chip light and dark with management actions`() {
        val dark = mutableStateOf(false)
        val actions = mutableListOf<VoiceAction?>()
        val model = SavedVoicesModel(CoroutineScope(Dispatchers.Main.immediate), { it() }) { action -> actions += action; library }
        runBlocking { model.perform(null) }
        compose.setContent {
            dev.chirp.android.ui.ChirpTheme(dark.value) { Surface { Column(Modifier.padding(16.dp)) {
                androidx.compose.material3.Text("Saved voices", style = androidx.compose.material3.MaterialTheme.typography.headlineSmall)
                SavedVoicesContent(model)
            } } }
        }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot(), false)
            val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
            File(output, "notes-saved-voices-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithText("⋯").performClick(); compose.onNodeWithText("Rename…").performClick()
        compose.onNode(hasSetTextAction()).performTextReplacement("Sam")
        compose.onNodeWithText("Rename", substring = false).performClick()
        compose.runOnIdle { assertEquals(VoiceAction.Rename(savedVoice.id, "Sam"), actions.last()) }
        compose.onNodeWithText("⋯").performClick(); compose.onNodeWithText("Forget…").performClick()
        compose.onNodeWithText("Forget", substring = false).performClick()
        compose.runOnIdle { assertEquals(VoiceAction.Forget(savedVoice.id), actions.last()) }
        compose.onNodeWithText("Forget all voices…").performClick(); compose.onNodeWithText("Forget", substring = false).performClick()
        compose.runOnIdle { assertEquals(VoiceAction.ForgetAll, actions.last()) }
        compose.onNodeWithText("Remember voices of people I name").performClick()
        compose.onNodeWithText("Keep voices").performClick()
        compose.runOnIdle { assertEquals(VoiceAction.Disable(false), actions.last()) }
    }
    @Test fun `recognized transcript chip and Not X menu light and dark`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), voicesMac, voices = { library })
        rig.model.refreshVoices(); rig.idle()
        rig.model.recorder.labelSpeakers = true
        rig.record().final("Synthetic meeting fixture", speakers = SpeakersResult("g",
            listOf(ServerTurn(0, 0.0, "Synthetic meeting fixture", "fixture")), matches = listOf(match())))
        rig.idle()
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) { Surface {
            TranscriptPane(rig.model, Modifier.padding(24.dp))
        } } }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot(), false)
            File(File(System.getProperty("chirp.screenshots")), "notes-auto-name-chip-${if (night) "dark" else "light"}.png")
                .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithText("Maya ✓").assertIsDisplayed()
        compose.onNodeWithContentDescription("Maya, recognised. Rename or merge this speaker").performClick()
        compose.onNodeWithText("Not Maya").assertIsDisplayed()
        compose.onNodeWithText("Update Maya’s saved voice").assertIsDisplayed()
        compose.onNodeWithText("Not Maya").performClick()
        compose.onNodeWithText("Person 1").assertIsDisplayed()
        compose.runOnIdle {
            val restored = NotesDocument.fromJson(rig.model.document.toJson())
            assertEquals("Person 1", restored.roster.displayName(1))
            assertNull(rig.model.document.roster.recognize(match()))
        }
    }

}
