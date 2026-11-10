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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.saveable.rememberSaveable
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

internal fun othersPosts(state: NodeState): List<FeedItem> {
    val selfId = state.profile?.directId ?: return emptyList()
    return state.feed.filter { it.channel == FeedNotes.POST && it.ownerId != selfId }
        .sortedByDescending { it.createdAt }
}

internal fun feedOwnerName(state: NodeState, ownerId: String): String {
    if (ownerId == state.profile?.directId) return state.profile?.name ?: "You"
    return state.contacts.firstOrNull { it.directId == ownerId }?.name ?: ownerId
}

internal fun feedOwnerJpeg(state: NodeState, ownerId: String): String? {
    if (ownerId == state.profile?.directId) return state.profile?.avatarJpegBase64
    return state.contacts.firstOrNull { it.directId == ownerId }?.avatarJpegBase64
}

private fun likedByMe(item: FeedItem, selfId: String?): Boolean =
    selfId != null && item.likes.any { it.fromId == selfId }

private fun formatFeedTime(ms: Long): String {
    val seconds = ((System.currentTimeMillis() - ms).coerceAtLeast(0)) / 1000
    return when {
        seconds < 60 -> "just now"
        seconds < 3600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3600}h"
        else -> "${seconds / 86_400}d"
    }
}

@Composable
internal fun FeedScreen(
    node: DirectNode,
    state: NodeState,
    onOpenStory: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
) {
    val selfId = state.profile?.directId
    val posts = othersPosts(state)
    var error by remember { mutableStateOf<String?>(null) }
    var viewingId by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize()) {
        Header("Posts from people you know", "Feed")
        if (selfId != null) {
            StoriesTray(node, state, selfId, onOpenStory) { error = it }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 20.dp)) }
        if (posts.isEmpty()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Muted("Posts your contacts add to their profile show up here. Like them or leave a comment — it stays between your phones.")
            }
        } else {
            LazyColumn(Modifier.weight(1f)) {
                items(posts, key = { it.id }) { item ->
                    FeedPostCard(node, state, item, onOpenProfile) { viewingId = item.id }
                    HorizontalDivider(color = Ink.border)
                }
            }
        }
    }
    FeedViewerDialog(node, state, viewingId, canDelete = false, onClose = { viewingId = null }, onError = { error = it })
}

@Composable
private fun FeedPostCard(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    onOpenProfile: (String) -> Unit,
    onOpen: () -> Unit,
) {
    val name = feedOwnerName(state, item.ownerId)
    Column(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { onOpenProfile(item.ownerId) }.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Avatar(name, jpegBytes(feedOwnerJpeg(state, item.ownerId)), 36.dp)
            Column(Modifier.weight(1f)) {
                Text(name, fontWeight = FontWeight.SemiBold)
                Text(formatFeedTime(item.createdAt), color = Ink.muted, fontSize = 12.sp)
            }
        }
        FeedThumb(node, item, Modifier.fillMaxWidth().aspectRatio(1f).clickable(onClick = onOpen))
        FeedActions(node, state, item, onOpen)
        if (item.caption.isNotBlank()) {
            Text(
                item.caption,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                fontSize = 15.sp,
            )
        }
        if (item.comments.isNotEmpty()) {
            Text(
                if (item.comments.size == 1) "View 1 comment" else "View all ${item.comments.size} comments",
                color = Ink.muted,
                fontSize = 13.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 2.dp).clickable(onClick = onOpen),
            )
        }
    }
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
    var viewingId by remember { mutableStateOf<String?>(null) }
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
                                Modifier.weight(1f).aspectRatio(1f).padding(1.dp).clickable { viewingId = item.id },
                            )
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f).aspectRatio(1f)) }
                    }
                }
            }
        }
    }
    FeedViewerDialog(node, state, viewingId, canDelete = canAdd, onClose = { viewingId = null }, onError = onError)
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
private fun FeedViewerDialog(
    node: DirectNode,
    state: NodeState,
    viewingId: String?,
    canDelete: Boolean,
    onClose: () -> Unit,
    onError: (String?) -> Unit,
) {
    val item = viewingId?.let { id -> state.feed.firstOrNull { it.id == id } }
    LaunchedEffect(viewingId, item == null) {
        if (viewingId != null && item == null) onClose()
    }
    if (item == null) return
    val scope = rememberCoroutineScope()
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        FeedLightbox(
            node, state, item, canDelete = canDelete,
            onDelete = {
                scope.launch {
                    try {
                        node.deleteFeed(item.id)
                        onClose()
                    } catch (error: Exception) {
                        onError(error.message)
                    }
                }
            },
            onClose = onClose,
            onError = onError,
        )
    }
}

@Composable
private fun FeedActions(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    onOpenComments: () -> Unit,
    light: Boolean = false,
) {
    val scope = rememberCoroutineScope()
    val selfId = state.profile?.directId
    val liked = likedByMe(item, selfId)
    val tint = if (light) Color.White else Ink.foreground
    val heart = if (liked) Color(0xFFE0245E) else tint
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { scope.launch { runCatching { node.likeFeed(item.id) } } }) {
            Icon(if (liked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder, "Like", tint = heart)
        }
        Text("${item.likes.size}", color = tint, fontWeight = FontWeight.Medium)
        IconButton(onClick = onOpenComments) {
            Icon(Icons.Outlined.ChatBubbleOutline, "Comments", tint = tint)
        }
        Text("${item.comments.size}", color = tint, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        if (item.likes.isNotEmpty()) {
            Text(
                if (item.likes.size == 1) "1 like" else "${item.likes.size} likes",
                color = tint,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(end = 12.dp),
            )
        }
    }
}

@Composable
private fun FeedLightbox(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    canDelete: Boolean,
    onDelete: () -> Unit,
    onClose: () -> Unit,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var draft by rememberSaveable(item.id) { mutableStateOf("") }
    BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(Ink.background).imePadding()) {
        Box(Modifier.fillMaxWidth().weight(1f).background(Color.Black)) {
            FeedMedia(node, item, Modifier.fillMaxSize())
            Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
                if (canDelete) {
                    IconButton(onClick = onDelete) { Icon(Icons.Outlined.Delete, "Delete", tint = Color.White) }
                }
            }
        }
        Column(Modifier.fillMaxWidth().background(Ink.surface)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val name = feedOwnerName(state, item.ownerId)
                Avatar(name, jpegBytes(feedOwnerJpeg(state, item.ownerId)), 32.dp)
                Column(Modifier.weight(1f)) {
                    Text(name, fontWeight = FontWeight.SemiBold)
                    Text(formatFeedTime(item.createdAt), color = Ink.muted, fontSize = 12.sp)
                }
            }
            FeedActions(node, state, item, onOpenComments = {})
            if (item.caption.isNotBlank()) {
                Text(item.caption, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp), fontSize = 15.sp)
            }
            if (item.comments.isEmpty()) {
                Muted("Be the first to comment.", Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            } else {
                Column(Modifier.fillMaxWidth().heightIn(max = 180.dp).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp)) {
                    item.comments.forEach { comment ->
                        val who = feedOwnerName(state, comment.fromId)
                        Column(Modifier.padding(vertical = 6.dp)) {
                            Text(who, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                            Text(comment.body, fontSize = 14.sp)
                            Text(formatFeedTime(comment.createdAt), color = Ink.muted, fontSize = 11.sp)
                        }
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.weight(1f)) {
                    Field(draft, { draft = it.take(FeedNotes.MAX_COMMENT) }, "Add a comment…")
                }
                IconButton(
                    onClick = {
                        val body = draft
                        scope.launch {
                            try {
                                node.commentFeed(item.id, body)
                                draft = ""
                                onError(null)
                            } catch (error: Exception) {
                                onError(error.message ?: "That comment was not saved.")
                            }
                        }
                    },
                    enabled = draft.isNotBlank(),
                ) {
                    Icon(Icons.AutoMirrored.Filled.Send, "Post comment", tint = if (draft.isNotBlank()) Ink.accent else Ink.muted)
                }
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
