package dev.chirp.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Shared by Notes and Settings. Model readiness never writes the user's preference. */
internal class NotesSpeakerModel(
    private val store: SettingsStore,
    private val scope: CoroutineScope,
    private val io: suspend (suspend () -> Unit) -> Unit,
    private val fetch: () -> Health?,
    private val request: (String) -> String?,
    private val changed: (Health?) -> Unit = {},
) {
    var enabled by mutableStateOf(store.notesLabelSpeakers)
        private set
    var health by mutableStateOf(store.health)
        private set
    var state by mutableStateOf(health?.speakersModel)
        private set
    var cancelFailed by mutableStateOf(false)
        private set
    private var wanted = false
    private var attempted = false
    private var pending = 0
    private var refreshing = 0
    private var poll: Job? = null
    private val commands = Mutex()
    val available get() = health?.notesSpeakers == true
    val ready get() = enabled && available && state == "ready"
    val retryable get() = cancelFailed || state == "failed"
    val status: String? get() = when {
        cancelFailed -> "Couldn’t cancel the speaker model download."
        !enabled || !available -> null
        state == "failed" -> "Couldn’t download the speaker model."
        state == "downloading" || state == "not_downloaded" -> {
            val size = health?.speakersModelBytes?.let { " (${(it / 1_000_000.0).toInt() + if (it % 1_000_000L > 0) 1 else 0} MB, once)" }.orEmpty()
            "Getting the speaker model ready$size…"
        }
        else -> null
    }

    /** A note starts capture first; the download and health check run independently. */
    fun activate() {
        enabled = store.notesLabelSpeakers
        wanted = enabled
        ensureDownload()
        refresh()
    }

    fun refresh() {
        enabled = store.notesLabelSpeakers
        if (!enabled) wanted = false
        val id = ++refreshing
        poll?.cancel()
        scope.launch {
            var latest: Health? = null
            io { latest = fetch() }
            if (id != refreshing || pending > 0) return@launch
            latest?.let {
                health = it; store.health = it; state = it.speakersModel
                changed(it)
                ensureDownload()
            }
            if (state == "downloading") poll = scope.launch { delay(3000); refresh() }
        }
    }

    fun setLabels(on: Boolean) {
        val cancel = !on && (state == "downloading" || pending > 0 || cancelFailed)
        enabled = on; store.notesLabelSpeakers = on
        wanted = on
        if (on) cancelFailed = false
        changed(health)
        if (cancel) command("cancel")
        else if (on) { attempted = false; ensureDownload(); refresh() }
    }

    fun retry() {
        if (cancelFailed) command("cancel")
        else if (enabled && available) { attempted = false; command("download") }
    }

    fun remove() { wanted = false; command("remove") }

    private fun ensureDownload() {
        if (wanted && enabled && available && state == "not_downloaded" && !attempted && pending == 0) command("download")
    }

    private fun command(action: String) {
        ++refreshing; poll?.cancel()
        if (action == "download") { attempted = true; state = "downloading" }
        pending++
        scope.launch {
            commands.withLock {
                // An off tap while a download POST is in flight queues cancellation behind it.
                var result: String? = null
                io { result = request(action) }
                pending--
                if (action == "cancel") cancelFailed = result == null || result == "downloading"
                state = result ?: "failed"
                changed(health)
                if (pending == 0) {
                    if (state == "downloading" || result != null) refresh()
                }
            }
        }
    }
}
