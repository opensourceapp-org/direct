package app.direct.messaging.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import kotlinx.coroutines.launch

private val pages = listOf(
    "A conversation between two phones" to "DIRECT creates your identity on this phone. A message is sealed here before it leaves, and the other phone is the only one that can open it.",
    "The bootstrap only introduces you" to "A small server helps the two phones find each other. It never sees your messages, photos, voice notes, or keys.",
    "Add someone with an ID or a QR code" to "Share your QR code. It includes your identity and the server address, so their phone can connect. The first message arrives as a request they accept.",
    "Offline messages wait on this phone" to "If the other phone is away, the message stays here and sends when they can be reached. There is no chat server holding a copy.",
)

@Composable
fun Intro(creating: Boolean, onDone: () -> Unit) {
    val pager = rememberPagerState { pages.size }
    val scope = rememberCoroutineScope()
    val last = pager.currentPage == pages.lastIndex
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("DIRECT", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp, color = Ink.accent)
        HorizontalPager(pager, Modifier.fillMaxWidth().weight(1f)) { page ->
            Column(Modifier.fillMaxWidth().padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Title(pages[page].first)
                Muted(pages[page].second)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                pages.indices.forEach { index ->
                    Box(
                        Modifier
                            .padding(4.dp)
                            .size(if (index == pager.currentPage) 8.dp else 6.dp)
                            .clip(CircleShape)
                            .background(if (index == pager.currentPage) Ink.accent else Ink.border),
                    )
                }
            }
            PrimaryButton(if (last) if (creating) "Create your identity" else "Done" else "Next") {
                if (last) onDone() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
            }
        }
    }
}
