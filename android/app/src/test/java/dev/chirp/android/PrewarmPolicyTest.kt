package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

class PrewarmPolicyTest {
    private var clock = 1_000L
    private val policy = PrewarmPolicy(now = { clock })
    private val minute = 60_000L

    @Test fun `a fresh process connects on press for any field`() {
        assertFalse(policy.shouldPrewarm(null)); assertFalse(policy.shouldPrewarm("com.example.notes"))
    }
    @Test fun `any field is warm for ten minutes after a dictation and then cold again`() {
        policy.dictated("com.example.notes")
        clock += 10 * minute - 1; assertTrue(policy.shouldPrewarm("com.example.other")); assertTrue(policy.shouldPrewarm(null))
        clock += 1; assertFalse(policy.shouldPrewarm("com.example.other")); assertFalse(policy.shouldPrewarm(null))
    }
    @Test fun `a package dictated into stays warm for a day while other packages go cold`() {
        policy.dictated("com.example.notes")
        clock += 11 * minute
        assertTrue(policy.shouldPrewarm("com.example.notes")); assertFalse(policy.shouldPrewarm("com.example.browser"))
        clock += 24 * 60 * minute - 11 * minute; assertFalse(policy.shouldPrewarm("com.example.notes"))
    }
    @Test fun `dictating again renews the package and a null package only renews the recent window`() {
        policy.dictated("com.example.notes"); clock += 23 * 60 * minute
        policy.dictated("com.example.notes"); clock += 23 * 60 * minute
        assertTrue(policy.shouldPrewarm("com.example.notes"))
        policy.dictated(null); clock += 11 * minute; assertFalse(policy.shouldPrewarm("com.example.browser"))
    }
    @Test fun `only the sixteen most recent packages are remembered`() {
        (1..17).forEach { policy.dictated("pkg$it") }
        clock += 11 * minute
        assertFalse(policy.shouldPrewarm("pkg1")); assertTrue(policy.shouldPrewarm("pkg2")); assertTrue(policy.shouldPrewarm("pkg17"))
    }
    @Test fun `health is due once a minute`() {
        assertTrue(policy.healthDue()); assertFalse(policy.healthDue())
        clock += minute - 1; assertFalse(policy.healthDue())
        clock += 1; assertTrue(policy.healthDue()); assertFalse(policy.healthDue())
    }
    @Test fun `a failed health check frees the slot`() {
        assertTrue(policy.healthDue()); policy.healthFailed(); assertTrue(policy.healthDue()); assertFalse(policy.healthDue())
    }
}
