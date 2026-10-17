package dev.chirp.android

data class CorrectionProfile(val id: String, val name: String, val description: String = "", val rewrites: Boolean = false,
                             val prompt: String? = null, val maxPromptChars: Int = 4000)

/** Package matching is exact: unrelated apps never inherit a style from a name substring. */
object CleanupStyles {
    const val MAX_PROMPT = 4000
    const val MAX_INSTRUCTIONS = 2000
    fun characterCount(value: String) = value.codePointCount(0, value.length)
    fun limitInstructions(value: String): String = limit(value, MAX_INSTRUCTIONS)
    fun limit(value: String, maximum: Int = MAX_PROMPT): String =
        value.substring(0, value.offsetByCodePoints(0, minOf(characterCount(value), maximum)))
    fun validId(value: String) = value.matches(Regex("[a-z][a-z0-9_-]{0,63}"))
    val defaults: Map<String, String> = buildMap {
        fun group(style: String, vararg packages: String) { packages.forEach { put(it, style) } }
        group("chat", "com.slack", "com.whatsapp", "com.discord", "com.google.android.apps.messaging", "com.samsung.android.messaging")
        group("email", "com.google.android.gm", "com.microsoft.office.outlook", "com.samsung.android.email.provider")
        group("code", "com.termux", "com.foxdebug.acode", "com.rhmsoft.code", "io.spck", "com.aor.droidedit", "com.aor.droidedit.pro")
        group("notes", "com.samsung.android.app.notes", "com.google.android.keep", "md.obsidian", "notion.id")
    }
    fun profiles(health: Health?): List<CorrectionProfile> {
        val reported = health?.correctionProfiles.orEmpty()
        return (reported.ifEmpty { listOf(CorrectionProfile("default", "Default")) } +
            CorrectionProfile("custom", "Custom", "Apply your custom instructions", true)).distinctBy { it.id }
    }
    fun resolve(packageName: String?, default: String, apps: Map<String, String>, profiles: List<CorrectionProfile>): CorrectionProfile {
        val id = apps[packageName] ?: default
        return profiles.firstOrNull { it.id == id } ?: profiles.firstOrNull { it.id == default }
            ?: profiles.firstOrNull { it.id == "default" } ?: CorrectionProfile("default", "Default")
    }
}
