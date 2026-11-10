package app.direct.messaging

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import app.direct.core.node.DirectNode
import app.direct.messaging.platform.CallMedia
import app.direct.messaging.platform.KeystoreSecretStore
import app.direct.messaging.platform.MessageAlerts
import app.direct.messaging.platform.OkHttpWebSocketFactory
import app.direct.messaging.platform.PresenceService
import app.direct.messaging.platform.WebRtcTransport
import app.direct.messaging.work.DeliveryWorker
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Owns the one DirectNode for this process. The node runs on a single-threaded dispatcher.
 * Foreground: the bootstrap reconnects immediately and the queue flushes.
 * Background: a foreground service keeps the socket up so inbound messages can notify,
 * and WorkManager retries pending outgoing messages when the network allows.
 */
class DirectApp : Application() {
    lateinit var node: DirectNode
        private set

    lateinit var calls: CallMedia
        private set

    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _openPeer = MutableStateFlow<String?>(null)
    val openPeer: StateFlow<String?> = _openPeer

    @Volatile
    var uiVisible: Boolean = true

    fun openFromNotification(peerId: String) {
        _openPeer.value = peerId
    }

    fun consumeOpenPeer() {
        _openPeer.value = null
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCreate() {
        super.onCreate()
        MessageAlerts.ensureChannels(this)
        node = DirectNode(
            secrets = KeystoreSecretStore(this),
            storeFile = File(noBackupFilesDir, "direct.store"),
            sockets = OkHttpWebSocketFactory(),
            transportFactory = { bootstrap, selfId, scope -> WebRtcTransport(this, bootstrap, selfId, scope) },
            dispatcher = Dispatchers.Default.limitedParallelism(1),
        )
        calls = CallMedia(this, appScope, node)
        node.onCallEvent = { calls.onEvent(it) }
        node.onInboundAlert = { alert ->
            if (!uiVisible) MessageAlerts.show(this, alert)
        }
        appScope.launch { node.start() }

        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                uiVisible = true
                PresenceService.stop(this@DirectApp)
                appScope.launch { node.onForeground() }
            }

            override fun onStop(owner: LifecycleOwner) {
                uiVisible = false
                if (node.state.value.profile != null) PresenceService.start(this@DirectApp)
                appScope.launch {
                    node.onBackground()
                    if (node.state.value.pending > 0) DeliveryWorker.schedule(this@DirectApp)
                }
            }
        })

        val connectivity = getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
        connectivity.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                appScope.launch { node.onNetworkAvailable() }
            }

            override fun onLost(network: Network) {
                if (connectivity.activeNetwork == null) appScope.launch { node.onNetworkLost() }
            }
        })
    }
}
