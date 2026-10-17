package dev.chirp.android

import java.net.InetAddress
import okhttp3.Dns
import org.junit.Assert.*
import org.junit.Test

class NetworkPermissionTest {
    private fun ip(value: String) = InetAddress.getByName(value)
    @Test fun `denied local permission gates resolved Wi-Fi addresses but never VPN routes`() {
        val denied = LocalNetworkPolicy({ false }, { false })
        val vpn = LocalNetworkPolicy({ false }, { true })
        for (host in listOf("10.0.2.2", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.2", "169.254.1.2", "fe80::1", "fd7a:115c:a1e0::1", "100.64.0.1", "100.127.255.254")) {
            val address = ip(host)
            assertThrows(WifiServerPermissionRequired::class.java) { denied.check(listOf(address)) }
            vpn.check(listOf(address))
            LocalNetworkPolicy({ true }, { false }).check(listOf(address))
        }
        for (host in listOf("127.0.0.1", "::1", "1.1.1.1", "100.63.255.255", "100.128.0.1", "172.32.0.1", "2001:4860:4860::8888")) {
            denied.check(listOf(ip(host)))
        }
    }
    @Test fun `DNS classification uses resolved addresses and preserves Tailscale access after denial`() {
        val tailnet = ip("100.100.1.2")
        val wifi = ip("192.168.5.10")
        val resolver = Dns { host -> listOf(if (host.endsWith(".ts.net")) tailnet else wifi) }
        val policy = LocalNetworkPolicy({ false }, { it == tailnet })
        val dns = PermissionDns(resolver, policy)
        assertEquals(listOf(tailnet), dns.lookup("synthetic.ts.net"))
        assertThrows(WifiServerPermissionRequired::class.java) { dns.lookup("synthetic.example.test") }
        assertEquals(listOf(tailnet), dns.lookup("synthetic.ts.net"))
    }
}
