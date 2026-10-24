package dev.chirp.android

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.speech.RecognizerIntent
import android.text.InputType
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.webkit.WebView
import android.widget.*

/** Debug-only editor matrix. Reports lengths and states, never clipboard, field or recognizer text. */
@SuppressLint("SetTextI18n")
class EditorProbeActivity : Activity() {
    private lateinit var report: TextView
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 24, 24, 24) }
        fun field(label: String, type: Int) = EditText(this).apply {
            hint = label; contentDescription = label; inputType = type; isSaveEnabled = false
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        val plain = field("Plain field", InputType.TYPE_CLASS_TEXT)
        column.addView(plain)
        column.addView(field("Password field", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        column.addView(object : View(this) {
            init { contentDescription = "Editable without set text"; isFocusableInTouchMode = true; minimumHeight = 80; setOnClickListener { requestFocus() } }
            override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(info)
                info.isEditable = true
                info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT)
            }
        })
        column.addView(WebView(this).apply {
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            loadData("<html><body><textarea aria-label='Web field' rows='3'></textarea></body></html>", "text/html", "UTF-8")
        }, LinearLayout.LayoutParams(-1, 180))
        report = TextView(this).apply { text = "Probe ready" }
        column.addView(Button(this).apply {
            text = "Paste and report length"; isAllCaps = false
            setOnClickListener {
                val clipboard = getSystemService(ClipboardManager::class.java)
                val clip = clipboard.primaryClip
                val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text
                plain.setText(text)
                report.text = "Paste length=${text?.length ?: 0}; sensitive=${clip?.description?.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true}"
            }
        })
        column.addView(Button(this).apply {
            text = "Recognize"; isAllCaps = false
            setOnClickListener {
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                if (intent.resolveActivity(packageManager) == null) report.text = "Recognizer unavailable"
                else @Suppress("DEPRECATION") startActivityForResult(intent, 1)
            }
        })
        column.addView(report)
        // Below the status bar on edge-to-edge targets, so every field can be tapped.
        setContentView(ScrollView(this).apply { fitsSystemWindows = true; addView(column) })
    }
    @Deprecated("Debug probe uses the external Activity result contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1) {
            val results = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS).orEmpty()
            report.text = "Recognize ok=${resultCode == RESULT_OK}; count=${results.size}; length=${results.firstOrNull()?.length ?: 0}"
        }
    }
}
