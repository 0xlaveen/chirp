package dev.chirp.android.shell

import dev.chirp.android.ConnectionFailure
import dev.chirp.android.DictationAction
import dev.chirp.android.Health
import dev.chirp.android.ui.StatusKind

/** The one fix Home's connection card offers. */
internal enum class HomeFix(val label: String) { Pair("Pair Mac"), Microphone("Allow"), TailscaleOn("Turn on"), Retry("Check again") }

internal class HomeStatus(val kind: StatusKind, val title: String, val body: String?, val fix: HomeFix?)

/**
 * What Home's connection card says, most blocking first: the same states the keyboard shows (not paired, microphone off,
 * Tailscale off, Mac offline). [failure] is the keyboard's classification of the last failed check; [reachable] is null until one finishes.
 */
internal fun homeStatus(paired: Boolean, host: String, microphone: Boolean, tailscaleOff: Boolean, checking: Boolean, reachable: Boolean?,
                        failure: ConnectionFailure.Kind?, health: Health?): HomeStatus = when {
    !paired -> HomeStatus(StatusKind.Warning, "Not paired", "Pair with your Mac to dictate", HomeFix.Pair)
    !microphone -> HomeStatus(StatusKind.Warning, "Microphone is off", "Allow microphone access to dictate", HomeFix.Microphone)
    tailscaleOff -> HomeStatus(StatusKind.Warning, DictationAction.TAILSCALE_OFF, "Turn it on to reach your Mac", HomeFix.TailscaleOn)
    checking -> HomeStatus(StatusKind.Info, "Checking your Mac…", host, null)
    reachable == false -> HomeStatus(StatusKind.Warning, "Mac offline", ConnectionFailure.status(failure), HomeFix.Retry)
    health?.ready == false -> HomeStatus(StatusKind.Info, "Mac is loading its speech model", host, null)
    reachable == true -> HomeStatus(StatusKind.Success, "Mac connected", listOfNotNull(host, health?.engine).joinToString(" · "), null)
    else -> HomeStatus(StatusKind.Info, "Paired", host, HomeFix.Retry)
}
