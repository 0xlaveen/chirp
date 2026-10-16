package dev.chirp.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    @Test fun `start uses frozen android pcm contract with correction opt in`() {
        val start = JSONObject(Protocol.start(false))
        assertEquals("start", start.getString("type"))
        assertEquals("android", start.getString("client"))
        assertEquals(16000, start.getInt("sample_rate"))
        assertEquals("pcm_s16le", start.getString("encoding"))
        assertFalse(start.getBoolean("correction"))
        assertTrue(JSONObject(Protocol.start(true)).getBoolean("correction"))
        assertFalse(start.has("token"))
    }
    @Test fun `decode all events and tolerate additive fields`() {
        assertEquals(ServerEvent.Ready(true), Protocol.decode("""{"type":"ready","debug_retention":true,"engine":"fake"}"""))
        assertEquals(ServerEvent.Partial(9, "synthetic text", "synthetic"), Protocol.decode("""{"type":"partial","seq":9,"text":"synthetic text","stable":"synthetic"}"""))
        assertEquals(ServerEvent.Final("Synthetic.", "synthetic", true), Protocol.decode("""{"type":"final","text":"Synthetic.","raw":"synthetic","corrected":true,"timings_ms":{}}"""))
        assertEquals(ServerEvent.Failure("auth"), Protocol.decode("""{"type":"error","code":"auth","message":"never shown"}"""))
        assertEquals(ServerEvent.Unknown, Protocol.decode("""{"type":"future"}"""))
    }
    @Test fun `authenticated health is required and privacy metadata preserved`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":true,"correction":"available","correction_leaves_machine":true,"correction_host":"example.test"}""")
        assertTrue(health.ready); assertTrue(health.debugRetention); assertTrue(health.correctionLeavesMachine)
        assertEquals("example.test", health.correctionHost)
        assertThrows(Exception::class.java) { Protocol.health("""{"ok":true}""") }
        assertThrows(Exception::class.java) { Protocol.decode("not json") }
        assertThrows(Exception::class.java) { Protocol.decode("""{"type":"final","text":"incomplete"}""") }
        assertThrows(Exception::class.java) { Protocol.decode("x".repeat(1_000_001)) }
    }
}
