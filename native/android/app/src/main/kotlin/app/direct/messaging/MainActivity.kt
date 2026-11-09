package app.direct.messaging

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import app.direct.messaging.platform.MessageAlerts
import app.direct.messaging.ui.DirectRoot
import app.direct.messaging.ui.DirectTheme

class MainActivity : ComponentActivity() {
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= 33) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        openFrom(intent)
        val node = (application as DirectApp).node
        setContent {
            DirectTheme {
                DirectRoot(node)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openFrom(intent)
    }

    private fun openFrom(intent: Intent?) {
        val peer = intent?.getStringExtra(MessageAlerts.EXTRA_PEER) ?: return
        (application as DirectApp).openFromNotification(peer)
    }
}
