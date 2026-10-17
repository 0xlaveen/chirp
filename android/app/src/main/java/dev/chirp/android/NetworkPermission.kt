package dev.chirp.android

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.IOException
import java.net.InetAddress
import okhttp3.Dns
import okhttp3.Interceptor

internal const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
internal fun Context.hasLocalNetworkAccess(): Boolean = Build.VERSION.SDK_INT < 37 ||
    ContextCompat.checkSelfPermission(this, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED

/** A typed, content-free failure that Setup can turn into a user-initiated permission request. */
internal class WifiServerPermissionRequired : IOException()

/** Android excludes VPN-routed traffic, including Tailscale CGNAT and ULA, from LNP.
 * https://developer.android.com/privacy-and-security/local-network-definition
 * Resolve off the UI/capture path and request access only for the actual paired destination.
 */
internal class LocalNetworkPolicy(
    private val granted: () -> Boolean,
    private val vpnRoute: (InetAddress) -> Boolean,
) {
    fun check(addresses: List<InetAddress>) {
        if (!granted() && addresses.any { localAddress(it) && !vpnRoute(it) }) throw WifiServerPermissionRequired()
    }
    companion object {
        fun localAddress(address: InetAddress): Boolean {
            if (address.isLoopbackAddress) return false
            val b = address.address.map { it.toInt() and 255 }
            if (b.size == 4) return b[0] == 10 || (b[0] == 172 && b[1] in 16..31) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) ||
                (b[0] == 100 && b[1] in 64..127) || address.isMulticastAddress
            return address.isLinkLocalAddress || address.isSiteLocalAddress || (b[0] and 254 == 252) || address.isMulticastAddress
        }
    }
}
internal class PermissionDns(private val upstream: Dns, private val policy: LocalNetworkPolicy) : Dns {
    override fun lookup(hostname: String): List<InetAddress> = upstream.lookup(hostname).also(policy::check)
}
internal fun Context.localNetworkPolicy() = LocalNetworkPolicy(::hasLocalNetworkAccess) { address ->
    val connectivity = getSystemService(ConnectivityManager::class.java)
    @Suppress("DEPRECATION")
    connectivity.allNetworks.any { network ->
        connectivity.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true &&
            connectivity.getLinkProperties(network)?.routes?.any { it.matches(address) } == true
    }
}
/** OkHttp can skip Dns for IP literals, so check those in its network worker too. */
internal fun literalPermissionInterceptor(policy: LocalNetworkPolicy) = Interceptor { chain ->
    val host = chain.request().url.host
    if (':' in host || host.all { it.isDigit() || it == '.' }) policy.check(listOf(InetAddress.getByName(host)))
    chain.proceed(chain.request())
}
