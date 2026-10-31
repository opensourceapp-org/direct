package app.direct.messaging

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import app.direct.messaging.ui.DirectRoot
import app.direct.messaging.ui.DirectTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val node = (application as DirectApp).node
        setContent {
            DirectTheme {
                DirectRoot(node)
            }
        }
    }
}
