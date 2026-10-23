package dev.chirp.android

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.InetAddress
import okhttp3.HttpUrl

/** What the keyboard may ask of the Tailscale app. Nothing here changes VPN state without a user tap. */
internal interface TailscaleControl {
    fun installed(): Boolean
    /** Any VPN network applied to Chirp. Only one VPN runs at a time; absence means a tailnet host is unreachable. */
    fun connected(): Boolean
    /** Called on the main thread when VPN availability changes; close stops watching. */
    fun watch(changed: () -> Unit): AutoCloseable
    /** Asks Tailscale's exported IPNReceiver to connect. Tailscale starts only with VPN consent the user already
     * gave it; otherwise it posts its own "open Tailscale" notification. Android's consent dialog is never bypassed. */
    fun connect(): Boolean
    fun open(): Boolean

    companion object {
        const val PACKAGE = "com.tailscale.ipn"
        const val RECEIVER = "com.tailscale.ipn.IPNReceiver"
        const val CONNECT = "com.tailscale.ipn.CONNECT_VPN"

        /** MagicDNS names, CGNAT 100.64.0.0/10 and the Tailscale ULA fd7a:115c:a1e0::/48. Never resolves DNS. */
        fun routes(base: HttpUrl): Boolean {
            val host = base.host.lowercase()
            if (host.endsWith(".ts.net")) return true
            val literal = ':' in host || (host.isNotEmpty() && host.all { it.isDigit() || it == '.' })
            if (!literal) return false
            val b = try { InetAddress.getByName(host).address.map { it.toInt() and 255 } } catch (_: Exception) { return false }
            return if (b.size == 4) b[0] == 100 && b[1] in 64..127
                else b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
    }
}

internal class AndroidTailscale(private val context: Context) : TailscaleControl {
    private val connectivity get() = context.getSystemService(ConnectivityManager::class.java)
    private fun launch() = context.packageManager.getLaunchIntentForPackage(TailscaleControl.PACKAGE)
    override fun installed() = launch() != null
    override fun connected(): Boolean = try {
        val manager = connectivity ?: return false
        @Suppress("DEPRECATION")
        manager.allNetworks.any { manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
    } catch (_: Exception) { false }
    override fun watch(changed: () -> Unit): AutoCloseable {
        val manager = connectivity ?: return AutoCloseable {}
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post(changed) }
            override fun onLost(network: Network) { main.post(changed) }
        }
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_VPN)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
        return try {
            manager.registerNetworkCallback(request, callback)
            AutoCloseable { main.removeCallbacksAndMessages(null); try { manager.unregisterNetworkCallback(callback) } catch (_: Exception) {} }
        } catch (_: Exception) { AutoCloseable {} }
    }
    override fun connect(): Boolean = installed() && try {
        context.sendBroadcast(Intent(TailscaleControl.CONNECT).setClassName(TailscaleControl.PACKAGE, TailscaleControl.RECEIVER))
        true
    } catch (_: Exception) { false }
    override fun open(): Boolean {
        val intent = launch() ?: return false
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }
}
