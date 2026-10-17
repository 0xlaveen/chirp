package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class PairingTest {
    @Test fun `pair preserves tailscale mount path and decodes token once`() {
        val pair = Pairing.parse("chirp://pair?url=https%3A%2F%2Fmac.example.ts.net%2Fchirp&token=synthetic%2Btoken%3D")
        assertEquals("https://mac.example.ts.net/chirp/v1/stream", pair.endpoint("v1/stream").toString())
        assertEquals("synthetic+token=", pair.token)
        assertFalse(pair.toString().contains(pair.token))
        assertEquals("https://mac.test/v1/health", Pairing.from("https://mac.test/", "fake").endpoint("v1/health").toString())
    }
    @Test fun `reject insecure malformed ambiguous or credential bearing links`() {
        listOf(
            "https://pair?url=https://mac.test&token=fake",
            "chirp://pair?url=http://mac.test&token=fake",
            "chirp://pair?url=https://user:secret@mac.test&token=fake",
            "chirp://pair?url=https://mac.test?secret=value&token=fake",
            "chirp://pair?url=https://mac.test&token=fake&token=other",
            "chirp://pair?url=https://mac.test&token=",
            "chirp://pair?url=https://mac.test&token=fake%0D%0Aheader",
            "chirp://pair?url=https://mac.test&token=fake#fragment",
            "chirp://pair?url=https://mac.test&token=%ZZ",
        ).forEach { uri -> assertThrows(Exception::class.java) { Pairing.parse(uri) } }
    }
    @Test fun `cleartext is confined to the isolated emulator in debug builds`() {
        val emulator = "http://10.0.2.2:7899"
        if (BuildConfig.DEBUG) assertEquals("10.0.2.2", Pairing.from(emulator, "synthetic").base.host)
        else assertThrows(Exception::class.java) { Pairing.from(emulator, "synthetic") }
        for (url in listOf("http://10.0.2.2", "http://10.0.2.2:7898", "http://10.0.2.3:7899", "http://localhost:7899", "http://192.168.1.1:7899")) {
            assertThrows(Exception::class.java) { Pairing.from(url, "synthetic") }
        }
    }

}
