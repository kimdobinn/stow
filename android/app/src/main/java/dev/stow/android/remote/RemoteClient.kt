package dev.stow.android.remote

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.SystemClock
import android.util.Log
import dev.stow.android.BuildConfig
import dev.stow.android.data.Prefs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Proxy
import java.net.URL

/** Why a call to the Mac's alarm remote didn't work. */
sealed class RemoteException(message: String) : Exception(message) {
    class NotPaired : RemoteException("Pair with the Mac first.")
    class Unreachable : RemoteException("Can't reach the Mac.")
    /** The Mac answered, but no (401 auth, 409 not now, 400 bad input). */
    class Rejected(val code: Int, message: String) : RemoteException(message)
}

/**
 * Talks to the HTTP server the Mac runs during an alarm, on the home Wi-Fi. Every request is
 * signed with the pairing key (see [RemoteSigner]). The Mac is found through, in order: a
 * debug-only `files/remote-host` override, the address that worked last, the addresses in the
 * latest alarm push, then Bonjour.
 */
class RemoteClient(private val context: Context, private val prefs: Prefs) {
    data class Endpoint(val host: String, val port: Int) {
        val url: String get() = "http://${if (':' in host) "[${host.replace("%", "%25")}]" else host}:$port"
    }

    @Volatile private var last: Endpoint? = null

    /**
     * A [deadline] ([SystemClock.elapsedRealtime]) is for callers on a short leash (the
     * notification's buttons): no attempt starts that its timeouts could carry past it.
     */
    suspend fun state(deadline: Long? = null): AlarmState = AlarmState.parse(request("GET", "/v1/state", null, deadline))

    suspend fun choices(): List<AlarmVideo> = AlarmState.choices(request("GET", "/v1/choices", null, null))

    /** One of the contract's actions, e.g. `{"action":"next"}`; returns the state after it. */
    suspend fun act(action: JSONObject, deadline: Long? = null): AlarmState =
        AlarmState.parse(request("POST", "/v1/action", action.toString(), deadline))

    private suspend fun request(method: String, path: String, body: String?, deadline: Long?): JSONObject = withContext(Dispatchers.IO) {
        try {
            sendToTheMac(method, path, body, deadline)
        } catch (e: RemoteException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Anything else (a bad address from a push, Bonjour trouble) is still just "can't reach it".
            Log.i("Stow", "Remote: $path failed (${e.javaClass.simpleName})")
            throw RemoteException.Unreachable()
        }
    }

    private suspend fun sendToTheMac(method: String, path: String, body: String?, deadline: Long?): JSONObject {
        // A key that's missing or doesn't decode to 32 bytes can't sign anything: pair again.
        val key = runCatching { prefs.pairingKey }.getOrNull()?.takeIf { it.size == 32 } ?: throw RemoteException.NotPaired()
        val bytes = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val tried = mutableSetOf<Endpoint>()
        fun timeLeft(): Long = deadline?.let { it - SystemClock.elapsedRealtime() } ?: Long.MAX_VALUE
        suspend fun attempt(endpoints: List<Endpoint>): JSONObject? {
            for (endpoint in endpoints) {
                if (timeLeft() < CONNECT_TIMEOUT + READ_TIMEOUT) return null
                if (!tried.add(endpoint)) continue
                val result = try {
                    send(endpoint, key, method, path, bytes)
                } catch (_: NotConnected) {
                    continue
                } catch (e: RemoteException) {
                    // It's there even if it said no: ask it first next time.
                    last = endpoint
                    throw e
                }
                last = endpoint
                return result
            }
            return null
        }
        return attempt(listOfNotNull(debugOverride(), last) + pushed())
            ?: (if (timeLeft() >= DISCOVERY_TIMEOUT + CONNECT_TIMEOUT + READ_TIMEOUT) attempt(listOfNotNull(discover())) else null)
            ?: throw RemoteException.Unreachable()
    }

    /** Connecting failed, so trying another address is safe (nothing reached the Mac). */
    private class NotConnected : Exception()

    private fun send(endpoint: Endpoint, key: ByteArray, method: String, path: String, body: ByteArray): JSONObject {
        val connection = connect(endpoint, key, method, path, body)
        try {
            // Past this point the Mac may already have acted, so a failure isn't retried elsewhere.
            try {
                if (method == "POST") connection.outputStream.use { it.write(body) }
                val code = connection.responseCode
                val text = (if (code < 400) connection.inputStream else connection.errorStream)
                    ?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
                val json = runCatching { JSONObject(text) }.getOrNull()
                if (code != 200 || json == null) {
                    val message = json?.optString("error")?.takeIf { it.isNotBlank() } ?: when (code) {
                        401 -> "The Mac didn't accept this phone. Check both clocks, or pair again."
                        409 -> "Not right now."
                        else -> "The Mac answered $code."
                    }
                    throw RemoteException.Rejected(code, message)
                }
                return json
            } catch (e: IOException) {
                Log.i("Stow", "Remote: ${endpoint.url}$path failed (${e.javaClass.simpleName})")
                throw RemoteException.Unreachable()
            }
        } finally {
            connection.disconnect()
        }
    }

    /** Opens the connection; any failure here (no answer, a bad host or port) means try the next address. */
    private fun connect(endpoint: Endpoint, key: ByteArray, method: String, path: String, body: ByteArray): HttpURLConnection {
        var connection: HttpURLConnection? = null
        try {
            connection = URL(endpoint.url + path).openConnection(Proxy.NO_PROXY) as HttpURLConnection
            connection.connectTimeout = CONNECT_TIMEOUT.toInt()
            connection.readTimeout = READ_TIMEOUT.toInt()
            connection.requestMethod = method
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            RemoteSigner.headers(key, method, path, body).forEach(connection::setRequestProperty)
            if (method == "POST") {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(body.size)
            }
            connection.connect()
            return connection
        } catch (e: Exception) {
            connection?.disconnect()
            if (e !is IOException && e !is IllegalArgumentException) throw e
            Log.i("Stow", "Remote: no answer at ${endpoint.url} (${e.javaClass.simpleName})")
            throw NotConnected()
        }
    }

    /** Debug builds: `files/remote-host` holding "host:port" (the emulator reaches the Mac at 10.0.2.2). */
    private fun debugOverride(): Endpoint? {
        if (!BuildConfig.DEBUG) return null
        val text = runCatching { File(context.filesDir, "remote-host").readText().trim() }.getOrNull() ?: return null
        val colon = text.lastIndexOf(':').takeIf { it > 0 } ?: return null
        val port = text.substring(colon + 1).toIntOrNull() ?: return null
        return Endpoint(text.substring(0, colon).trim('[', ']'), port)
    }

    private fun pushed(): List<Endpoint> =
        prefs.alarm.value?.let { alarm -> alarm.hosts.map { Endpoint(it, alarm.port) } }.orEmpty()

    /** Bonjour: the Mac advertises `_stow-remote._tcp` only while an alarm runs. */
    private suspend fun discover(): Endpoint? {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return null
        val found = CompletableDeferred<Endpoint?>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(service: NsdServiceInfo) = resolve(nsd, service) { it?.let(found::complete) }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.i("Stow", "Remote: Bonjour discovery failed ($errorCode)")
                found.complete(null)
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onServiceLost(service: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        return try {
            withTimeoutOrNull(DISCOVERY_TIMEOUT) { found.await() }
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
    }

    @Suppress("DEPRECATION") // registerServiceInfoCallback needs API 34; minSdk is 31.
    private fun resolve(nsd: NsdManager, service: NsdServiceInfo, done: (Endpoint?) -> Unit) {
        nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) {
                val addresses: List<InetAddress> = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
                done(address?.hostAddress?.let { Endpoint(it, info.port) })
            }
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done(null)
        })
    }

    companion object {
        const val SERVICE_TYPE = "_stow-remote._tcp"
        private const val CONNECT_TIMEOUT = 2_000L
        private const val READ_TIMEOUT = 4_000L
        private const val DISCOVERY_TIMEOUT = 5_000L
    }
}
