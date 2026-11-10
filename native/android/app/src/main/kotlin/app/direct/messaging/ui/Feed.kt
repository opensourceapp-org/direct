package app.direct.messaging.ui

import android.graphics.BitmapFactory
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.Image
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.core.protocol.FeedNotes
import app.direct.core.store.FeedItem
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

internal fun liveStories(state: NodeState, ownerId: String): List<FeedItem> =
    state.feed.filter { it.ownerId == ownerId && it.channel == FeedNotes.STORY }.sortedBy { it.createdAt }

internal fun profilePosts(state: NodeState, ownerId: String): List<FeedItem> =
    state.feed.filter { it.ownerId == ownerId && it.channel == FeedNotes.POST }.sortedByDescending { it.createdAt }

internal fun storyOwners(state: NodeState, selfId: String): List<String> {
    val owners = state.feed.filter { it.channel == FeedNotes.STORY }.groupBy { it.ownerId }
    val contacts = state.contacts.filter { it.accepted && !it.blocked && owners.containsKey(it.directId) }
        .sortedBy { contact -> owners[contact.directId]?.all { it.seen } == true }
    return listOf(selfId) + contacts.map { it.directId }
}

@Composable
internal fun StoriesTray(
    node: DirectNode,
    state: NodeState,
    selfId: String,
    onOpenStory: (String) -> Unit,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val prepared = MediaPrep.visual(context, uri)
                val kind = if (prepared.kind == "gif") "image" else prepared.kind
                if (kind !in FeedNotes.KINDS) onError("Stories take a photo or a video.")
                else {
                    node.publishFeed(FeedNotes.STORY, kind, prepared.mime, prepared.name, prepared.bytes, "")
                    onError(null)
                }
            } catch (error: Exception) {
                onError(error.message ?: "That story was not added.")
            }
        }
    }
    val video = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val prepared = MediaPrep.video(context, uri)
                node.publishFeed(FeedNotes.STORY, prepared.kind, prepared.mime, prepared.name, prepared.bytes, "")
                onError(null)
            } catch (error: Exception) {
                onError(error.message ?: "That story was not added.")
            }
        }
    }
    val owners = storyOwners(state, selfId)
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        owners.forEach { ownerId ->
            val stories = liveStories(state, ownerId)
            val self = ownerId == selfId
            val name = if (self) "Your story" else state.contacts.firstOrNull { it.directId == ownerId }?.name ?: ownerId
            val jpeg = if (self) state.profile?.avatarJpegBase64 else state.contacts.firstOrNull { it.directId == ownerId }?.avatarJpegBase64
            val unseen = stories.any { !it.seen }
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(72.dp)) {
                Box(contentAlignment = Alignment.BottomEnd) {
                    Box(
                        Modifier
                            .size(68.dp)
                            .clickable {
                                if (stories.isNotEmpty()) onOpenStory(ownerId)
                                else if (self) photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (stories.isNotEmpty()) StoryRing(unseen)
                        Avatar(name, jpegBytes(jpeg), 56.dp)
                    }
                    if (self) {
                        Box(
                            Modifier
                                .size(20.dp)
                                .clip(CircleShape)
                                .background(Ink.accent)
                                .clickable { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.Add, "Add story", tint = Color.White, modifier = Modifier.size(14.dp))
                        }
                    }
                }
                Text(name, fontSize = 11.sp, color = Ink.foreground, maxLines = 1, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(72.dp).clickable {
            video.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
        }) {
            Box(Modifier.size(68.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(56.dp).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Videocam, "Add video story", tint = Ink.accent)
                }
            }
            Text("Video", fontSize = 11.sp, color = Ink.muted, modifier = Modifier.padding(top = 4.dp))
        }
    }
}

@Composable
private fun StoryRing(unseen: Boolean) {
    val colors = if (unseen) listOf(Color(0xFFE1306C), Color(0xFFF77737), Color(0xFFFCAF45)) else listOf(Ink.border, Ink.border)
    Canvas(Modifier.fillMaxSize()) {
        drawCircle(
            brush = Brush.sweepGradient(colors),
            radius = size.minDimension / 2 - 2.dp.toPx(),
            style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}

@Composable
internal fun StoryViewer(node: DirectNode, state: NodeState, ownerId: String, onClose: () -> Unit) {
    val stories = liveStories(state, ownerId)
    if (stories.isEmpty()) {
        LaunchedEffect(ownerId) { onClose() }
        return
    }
    var index by remember(ownerId) { mutableIntStateOf(0) }
    val current = stories.getOrNull(index.coerceIn(0, stories.lastIndex)) ?: return
    val selfId = state.profile?.directId
    val name = if (ownerId == selfId) state.profile?.name ?: "You" else state.contacts.firstOrNull { it.directId == ownerId }?.name ?: ownerId
    BackHandler(onBack = onClose)
    LaunchedEffect(ownerId) { node.markStoriesSeen(ownerId) }
    LaunchedEffect(current.id) {
        if (current.kind == "video") return@LaunchedEffect
        delay(5_000)
        if (index < stories.lastIndex) index += 1 else onClose()
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        FeedMedia(node, current, Modifier.fillMaxSize())
        Row(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxSize().clickable {
                if (index == 0) onClose() else index -= 1
            })
            Box(Modifier.weight(2f).fillMaxSize().clickable {
                if (index < stories.lastIndex) index += 1 else onClose()
            })
        }
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                stories.forEachIndexed { i, _ ->
                    Box(
                        Modifier
                            .weight(1f)
                            .height(3.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(if (i <= index) Color.White else Color.White.copy(alpha = 0.28f)),
                    )
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(name, color = Color.White, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, "Close", tint = Color.White)
                }
            }
        }
    }
}

@Composable
internal fun ProfilePosts(
    node: DirectNode,
    state: NodeState,
    ownerId: String,
    canAdd: Boolean,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val posts = profilePosts(state, ownerId)
    var viewing by remember { mutableStateOf<FeedItem?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val prepared = MediaPrep.visual(context, uri)
                val kind = when (prepared.kind) {
                    "gif" -> "image"
                    "image", "video" -> prepared.kind
                    else -> {
                        onError("Profile posts take a photo or a video.")
                        return@launch
                    }
                }
                node.publishFeed(FeedNotes.POST, kind, prepared.mime, prepared.name, prepared.bytes, "")
                onError(null)
            } catch (error: Exception) {
                onError(error.message ?: "That post was not added.")
            }
        }
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Label("Photos and videos")
            if (canAdd) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    IconButton(onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }) {
                        Icon(Icons.Outlined.PhotoCamera, "Add to profile", tint = Ink.accent)
                    }
                }
            }
        }
        if (posts.isEmpty()) {
            Muted(
                if (canAdd) "Add photos and videos to your profile. Accepted contacts see them."
                else "No photos or videos on this profile yet.",
                Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )
        } else {
            Column(Modifier.fillMaxWidth().padding(horizontal = 1.dp)) {
                posts.chunked(3).forEach { row ->
                    Row(Modifier.fillMaxWidth()) {
                        row.forEach { item ->
                            FeedThumb(
                                node,
                                item,
                                Modifier.weight(1f).aspectRatio(1f).padding(1.dp).clickable { viewing = item },
                            )
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f).aspectRatio(1f)) }
                    }
                }
            }
        }
    }
    viewing?.let { item ->
        Dialog(onDismissRequest = { viewing = null }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            FeedLightbox(node, item, canDelete = canAdd, onDelete = {
                scope.launch {
                    try {
                        node.deleteFeed(item.id)
                        viewing = null
                    } catch (error: Exception) {
                        onError(error.message)
                    }
                }
            }, onClose = { viewing = null })
        }
    }
}

@Composable
internal fun ContactProfileScreen(node: DirectNode, state: NodeState, peerId: String, back: () -> Unit) {
    val contact = state.contacts.firstOrNull { it.directId == peerId }
    val self = peerId == state.profile?.directId
    val name = if (self) state.profile?.name ?: "You" else contact?.name ?: peerId
    val jpeg = if (self) state.profile?.avatarJpegBase64 else contact?.avatarJpegBase64
    val about = if (self) state.profile?.status.orEmpty() else contact?.about.orEmpty()
    val stories = liveStories(state, peerId)
    var storyOpen by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    BackHandler(onBack = back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground) }
            Title(name)
        }
        Row(Modifier.padding(horizontal = 20.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.clickable(enabled = stories.isNotEmpty()) { storyOpen = true }) {
                if (stories.isNotEmpty()) {
                    Box(Modifier.size(84.dp), contentAlignment = Alignment.Center) {
                        StoryRing(stories.any { !it.seen })
                        Avatar(name, jpegBytes(jpeg), 72.dp)
                    }
                } else {
                    Avatar(name, jpegBytes(jpeg), 72.dp)
                }
            }
            Column(Modifier.weight(1f)) {
                Text(name, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                if (about.isNotBlank()) Text(about, color = Ink.muted)
                Text("${profilePosts(state, peerId).size} posts", color = Ink.muted, fontSize = 13.sp)
            }
        }
        error?.let { Text(it, color = Ink.danger, modifier = Modifier.padding(horizontal = 20.dp)) }
        ProfilePosts(node, state, peerId, canAdd = self, onError = { error = it })
    }
    if (storyOpen) StoryViewer(node, state, peerId) { storyOpen = false }
}

@Composable
private fun FeedThumb(node: DirectNode, item: FeedItem, modifier: Modifier) {
    var bytes by remember(item.id, item.mediaFile) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(item.id, item.mediaFile) { bytes = node.readFeed(item.id) }
    Box(modifier.background(Ink.surface), contentAlignment = Alignment.Center) {
        val bitmap = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }?.asImageBitmap()
        if (bitmap != null) {
            Image(bitmap, item.name, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Box(Modifier.fillMaxSize().background(Ink.accentSoft))
        }
        if (item.kind == "video") {
            Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(28.dp))
        }
    }
}

@Composable
private fun FeedLightbox(node: DirectNode, item: FeedItem, canDelete: Boolean, onDelete: () -> Unit, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Box(Modifier.fillMaxSize().background(Color.Black).clickable(onClick = onClose)) {
        FeedMedia(node, item, Modifier.fillMaxSize())
        Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
            if (canDelete) {
                IconButton(onClick = onDelete) { Icon(Icons.Outlined.Delete, "Delete", tint = Color.White) }
            }
        }
    }
}

@Composable
private fun FeedMedia(node: DirectNode, item: FeedItem, modifier: Modifier) {
    val context = LocalContext.current
    var bytes by remember(item.id, item.mediaFile) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(item.id, item.mediaFile) { bytes = node.readFeed(item.id) }
    val data = bytes
    if (data == null) {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text("Loading", color = Color.White)
        }
        return
    }
    if (item.kind == "video") {
        val file = remember(item.id, data) {
            File(context.cacheDir, "${item.id}.mp4").also { it.writeBytes(data) }
        }
        AndroidView(
            factory = { viewContext ->
                VideoView(viewContext).apply {
                    setVideoPath(file.absolutePath)
                    setOnPreparedListener { it.isLooping = false; start() }
                }
            },
            modifier = modifier,
        )
    } else {
        val bitmap = remember(data) { BitmapFactory.decodeByteArray(data, 0, data.size)?.asImageBitmap() }
        if (bitmap != null) {
            Image(bitmap, item.caption.ifBlank { item.name }, modifier, contentScale = ContentScale.Fit)
        }
    }
}

private fun jpegBytes(encoded: String?): ByteArray? =
    encoded?.let { runCatching { app.direct.core.Encoding.fromBase64Url(it) }.getOrNull() }
