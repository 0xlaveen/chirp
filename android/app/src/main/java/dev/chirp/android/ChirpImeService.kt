package dev.chirp.android

import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.View
import android.view.inputmethod.EditorInfo
import helium314.keyboard.event.Event
import helium314.keyboard.keyboard.internal.keyboard_parser.floris.KeyCode
import helium314.keyboard.latin.LatinIME

/** The existing IME component now contains HeliBoard plus in-process Chirp dictation. */
open class ChirpImeService : LatinIME() {
    private val handler = Handler(Looper.getMainLooper())
    private var reconfiguring = false
    private val dictation by lazy {
        KeyboardDictation(this, ::createCapture, ::createTransport, ::prepareChirpDictation, ::finishChirpDictation)
    }
    protected open fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit): Capture =
        captureForBuild(this, frame, level, done)
    protected open fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
        StreamTransport(client, pairing, dispatch = { callback -> handler.post { callback() } }, event = event, failure = failure)

    override fun onEvaluateFullscreenMode() = false
    override fun onCreateInputView(): View = super.onCreateInputView()
    // HeliBoard's InputView positions its keyboard frame at the bottom and owns window insets.
    // Insert in that frame, including when HeliBoard replaces the view on a theme/layout change.
    override fun setInputView(keys: View) {
        val suggestions = keys.findViewById<android.widget.RelativeLayout>(helium314.keyboard.latin.R.id.suggestion_strip_view)
        suggestions.findViewWithTag<View>("chirp_strip")?.let(suggestions::removeView)
        val strip = KeyboardStrip(ContextThemeWrapper(this, R.style.Theme_Chirp)).apply { tag = "chirp_strip" }
        strip.mount(suggestions)
        dictation.attach(strip)
        super.setInputView(keys)
    }
    override fun onChirpVoiceClick(): Boolean { dictation.toggle(); return true }
    override fun onChirpVoiceTouch(action: Int): Boolean { dictation.touch(action); return true }
    override fun onEvent(event: Event) {
        if (event.keyCode != KeyCode.VOICE_INPUT) dictation.beforeEdit()
        super.onEvent(event)
    }
    override fun onTextInput(rawText: String?) { dictation.beforeEdit(); super.onTextInput(rawText) }
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        if (!reconfiguring) dictation.input(attribute, restarting)
        super.onStartInput(attribute, restarting)
    }
    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        dictation.shown()
    }
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
        val owned = dictation.ownsComposition
        dictation.selection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        if (!owned) super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
    }
    override fun onFinishInputView(finishingInput: Boolean) {
        if (!reconfiguring) dictation.hidden()
        super.onFinishInputView(finishingInput)
    }
    override fun onWindowHidden() { if (!reconfiguring) dictation.hidden(); super.onWindowHidden() }
    override fun onFinishInput() { if (!reconfiguring) dictation.hidden(); super.onFinishInput() }
    override fun onUnbindInput() { dictation.hidden(); super.onUnbindInput() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        reconfiguring = true
        try { super.onConfigurationChanged(newConfig) } finally { reconfiguring = false }
    }
    override fun onDestroy() { dictation.destroy(); handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
