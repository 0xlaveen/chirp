package dev.chirp.android

import android.content.Context
import android.os.Build
import android.security.advancedprotection.AdvancedProtectionManager

internal fun interface AdvancedProtection { fun enabled(): Boolean }

internal class AndroidAdvancedProtection(private val context: Context) : AdvancedProtection {
    override fun enabled(): Boolean = Build.VERSION.SDK_INT >= 36 &&
        context.getSystemService(AdvancedProtectionManager::class.java)?.isAdvancedProtectionEnabled == true
}
