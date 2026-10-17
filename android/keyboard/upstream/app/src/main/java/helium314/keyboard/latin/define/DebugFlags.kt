/*
 * Copyright (C) 2014 The Android Open Source Project
 * modified
 * SPDX-License-Identifier: Apache-2.0 AND GPL-3.0-only
 */

package helium314.keyboard.latin.define

import android.content.Context

object DebugFlags {
    @JvmField
    var DEBUG_ENABLED = false

    // CHIRP: the host installs a bounded, message-free crash handler. Upstream's
    // reporter and debug mode can retain editor content, so neither is installed.
    @Suppress("UNUSED_PARAMETER")
    fun init(context: Context) { DEBUG_ENABLED = false }
}
