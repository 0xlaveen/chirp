package dev.chirp.android

import android.media.MediaPlayer
import android.os.Looper
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowMediaPlayer

/** UI playback state follows MediaPlayer, with the codec round trip checked separately on the emulator. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesAudioPlayerTest {
    private val library = NotesSessions(RuntimeEnvironment.getApplication(), SoftwareHistoryKeys())
    private var media: MediaPlayer? = null
    private val player = NotesAudioPlayer(library, newPlayer = { MediaPlayer().also { media = it } }, read = { it() })
    private fun prepareClip(): String {
        val doc = NotesDocument().apply { userEdit(0, 0, "Synthetic notes"); append(NotesSegment(0, 0.0, "Synthetic speech")) }
        library.put(doc.uid, doc.toJson())
        library.storeClip(doc.uid, 0, 0.0, 32000, byteArrayOf(1, 2, 3, 4))
        ShadowMediaPlayer.setMediaInfoProvider { ShadowMediaPlayer.MediaInfo(5000, -1) }
        return doc.uid
    }
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    @After fun close() { player.stop() }

    @Test fun `only a prepared started clip is highlighted and completion clears it`() {
        val id = prepareClip()
        player.play(id, 0); idle()
        assertNull("loading is not playing", player.playing.value)
        val shadow = shadowOf(requireNotNull(media))
        shadow.invokePreparedListener()
        assertEquals(NotesClipRef(id, 0), player.playing.value)
        assertTrue(shadow.isReallyPlaying)
        shadow.invokeCompletionListener()
        assertNull(player.playing.value)
        assertEquals(ShadowMediaPlayer.State.END, shadow.state)
        assertFalse(player.failed.value)
    }

    @Test fun `a decoder error clears the highlight and is exposed to the transcript`() {
        val id = prepareClip()
        player.play(id, 0); idle()
        val shadow = shadowOf(requireNotNull(media))
        shadow.invokePreparedListener()
        shadow.invokeErrorListener(MediaPlayer.MEDIA_ERROR_UNKNOWN, 0)
        assertNull(player.playing.value)
        assertTrue(player.failed.value)
        assertEquals(ShadowMediaPlayer.State.END, shadow.state)
    }

    @Test fun `closing before the asynchronous read returns never creates a player`() {
        val id = prepareClip()
        var work: (() -> Unit)? = null
        val pending = NotesAudioPlayer(library, newPlayer = { error("closed before read") }, read = { work = it })
        pending.play(id, 0); pending.stop()
        requireNotNull(work).invoke(); idle()
        assertNull(pending.playing.value)
        assertFalse(pending.failed.value)
    }

    @Test fun `the in-memory source wipes decrypted bytes on close`() {
        val bytes = byteArrayOf(10, 20, 30, 40)
        val source = BytesDataSource(bytes)
        val target = ByteArray(8)
        assertEquals(2, source.readAt(2, target, 0, 8))
        assertArrayEquals(byteArrayOf(30, 40, 0, 0, 0, 0, 0, 0), target)
        assertEquals(-1, source.readAt(4, target, 0, 1))
        source.close()
        assertTrue(bytes.all { it == 0.toByte() })
    }
}
