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
import app.direct.messaging.platform.OkHttpWebSocketFactory
import app.direct.messaging.platform.WebRtcTransport
import app.direct.messaging.work.DeliveryWorker
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Owns the one DirectNode for this process. The node runs on a single-threaded dispatcher.
 * Foreground: the bootstrap reconnects immediately and the queue flushes.
 * Background: the store is saved and WorkManager retries pending messages when the network allows.
 */
class DirectApp : Application() {
    lateinit var node: DirectNode
        private set

    lateinit var calls: CallMedia
        private set

    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCreate() {
        super.onCreate()
        node = DirectNode(
            secrets = KeystoreSecretStore(this),
            storeFile = File(noBackupFilesDir, "direct.store"),
            sockets = OkHttpWebSocketFactory(),
            transportFactory = { bootstrap, selfId, scope -> WebRtcTransport(this, bootstrap, selfId, scope) },
            dispatcher = Dispatchers.Default.limitedParallelism(1),
        )
        calls = CallMedia(this, appScope, node)
        node.onCallEvent = { calls.onEvent(it) }
        appScope.launch { node.start() }

        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                appScope.launch { node.onForeground() }
            }

            override fun onStop(owner: LifecycleOwner) {
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
