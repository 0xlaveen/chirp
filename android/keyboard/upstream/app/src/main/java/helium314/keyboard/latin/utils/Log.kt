package helium314.keyboard.latin.utils

import android.os.Build
import java.time.LocalDateTime
import java.util.Date

/**
 * Logger that does the android logging, but also allows reading the log in the app.
 * It's only a little slower than the android logger, but since both are used we end up at
 * half performance (still fast enough to not be noticeable, unless spamming thousands of log lines)
 */
// CHIRP: no keyboard/editor content or exception messages in logcat or the in-app log.
// The host's CrashLog records only exception classes and message-free stack frames.
@Suppress("UNUSED_PARAMETER")
object Log {
    @JvmStatic fun wtf(tag: String?, message: String) {}
    @JvmStatic fun e(tag: String?, message: String, e: Throwable?) {}
    @JvmStatic fun e(tag: String?, message: String) {}
    @JvmStatic fun w(tag: String?, message: String, e: Throwable?) {}
    @JvmStatic fun w(tag: String?, message: String) {}
    @JvmStatic fun i(tag: String?, message: String, e: Throwable?) {}
    @JvmStatic fun i(tag: String?, message: String) {}
    @JvmStatic fun d(tag: String?, message: String, e: Throwable?) {}
    @JvmStatic fun d(tag: String?, message: String) {}
    @JvmStatic fun v(tag: String?, message: String) {}
    fun getLog(maxLines: Int = 0): List<LogLine> = emptyList()
}

data class LogLine(val level: Char, val tag: String?, val message: String) {

    // time can be Date or LocalDateTime, doesn't matter because but it's used for toString only
    private val time = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        LocalDateTime.now()
    } else {
        Date(System.currentTimeMillis())
    }

    override fun toString(): String = // should look like a normal android log line, at least for api26+
        "${time.toString().replace('T', ' ')} $level $tag: $message"
}
