package app.direct.messaging.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Chat
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DynamicFeed
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.Image
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.core.protocol.ChatNotes
import app.direct.core.protocol.FeedNotes
import app.direct.core.store.FeedItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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

internal fun savedFeed(state: NodeState): List<FeedItem> {
    val byId = state.feed.associateBy { it.id }
    return state.savedPosts.mapNotNull { byId[it] }.filter { it.channel == FeedNotes.POST }
}

internal fun othersPosts(state: NodeState): List<FeedItem> {
    val selfId = state.profile?.directId ?: return emptyList()
    return state.feed.filter { item ->
        item.channel == FeedNotes.POST && item.ownerId != selfId
            && state.contacts.firstOrNull { it.directId == item.ownerId }?.blocked != true
    }.sortedByDescending { it.createdAt }
}

internal fun feedOwnerName(state: NodeState, ownerId: String): String {
    if (ownerId == state.profile?.directId) return state.profile?.name ?: "You"
    return state.contacts.firstOrNull { it.directId == ownerId }?.name ?: ownerId
}

internal fun feedOwnerJpeg(state: NodeState, ownerId: String): String? {
    if (ownerId == state.profile?.directId) return state.profile?.avatarJpegBase64
    return state.contacts.firstOrNull { it.directId == ownerId }?.avatarJpegBase64
}

internal fun feedTaggedLine(state: NodeState, ids: List<String>): String {
    val names = ids.map { feedOwnerName(state, it) }
    if (names.isEmpty()) return ""
    if (names.size == 1) return "with ${names[0]}"
    if (names.size == 2) return "with ${names[0]} and ${names[1]}"
    return "with ${names.dropLast(1).joinToString(", ")} and ${names.last()}"
}

internal fun feedPoster(bytes: ByteArray, kind: String): Bitmap? =
    if (kind == "video") videoPoster(bytes) else BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

internal fun videoPoster(bytes: ByteArray): Bitmap? {
    val file = File.createTempFile("direct-thumb", ".mp4")
    val retriever = MediaMetadataRetriever()
    return try {
        file.writeBytes(bytes)
        retriever.setDataSource(file.absolutePath)
        retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            ?: retriever.frameAtTime
    } catch (_: Exception) {
        null
    } finally {
        retriever.release()
        file.delete()
    }
}

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
    onOpenMedia: (String) -> Unit,
    onOpenComments: (String) -> Unit,
) {
    val selfId = state.profile?.directId
    val posts = othersPosts(state)
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().background(Ink.background)) {
        Header("From people you know", "Feed")
        Column(Modifier.fillMaxWidth().background(Ink.surface)) {
            if (selfId != null) {
                StoriesTray(node, state, selfId, onOpenStory) { error = it }
            }
        }
        HorizontalDivider(color = Ink.border)
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) }
        if (posts.isEmpty()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(64.dp).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.DynamicFeed, null, tint = Ink.accent, modifier = Modifier.size(28.dp))
                }
                Text("No posts yet", fontWeight = FontWeight.SemiBold, fontSize = 18.sp, modifier = Modifier.padding(top = 16.dp))
                Text(
                    "When a contact adds photos or videos to their profile, they show up here.",
                    color = Ink.muted,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        } else {
            LazyColumn(Modifier.weight(1f)) {
                items(posts, key = { it.id }) { item ->
                    FeedPostCard(node, state, item, onOpenProfile, { onOpenMedia(item.id) }) { onOpenComments(item.id) }
                    Spacer(Modifier.height(10.dp))
                }
            }
        }
    }
}

@Composable
private fun FeedPostCard(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    onOpenProfile: (String) -> Unit,
    onOpenMedia: () -> Unit,
    onOpenComments: () -> Unit,
) {
    val name = feedOwnerName(state, item.ownerId)
    Column(Modifier.fillMaxWidth().background(Ink.surface).padding(bottom = 10.dp)) {
        Row(
            Modifier.fillMaxWidth().clickable { onOpenProfile(item.ownerId) }.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Avatar(name, jpegBytes(feedOwnerJpeg(state, item.ownerId)), 34.dp)
            Column(Modifier.weight(1f)) {
                Text(name, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                Text(formatFeedTime(item.createdAt), color = Ink.muted, fontSize = 12.sp)
            }
        }
        FeedThumb(
            node,
            item,
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp)
                .aspectRatio(1f)
                .clip(RoundedCornerShape(18.dp))
                .clickable(onClickLabel = "View full size", onClick = onOpenMedia),
        )
        if (item.caption.isNotBlank()) {
            Text(
                item.caption,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp),
                fontSize = 14.sp,
            )
        }
        if (item.tags.isNotEmpty()) {
            Text(
                feedTaggedLine(state, item.tags),
                color = Ink.muted,
                fontSize = 13.sp,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = if (item.caption.isNotBlank()) 2.dp else 10.dp),
            )
        }
        FeedActions(node, state, item, onOpenComments)
        if (item.comments.isNotEmpty()) {
            Text(
                if (item.comments.size == 1) "1 comment" else "${item.comments.size} comments",
                color = Ink.muted,
                fontSize = 13.sp,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp).clickable(onClick = onOpenComments),
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
    val mine = ownerId == selfId
    val name = if (mine) state.profile?.name ?: "You" else state.contacts.firstOrNull { it.directId == ownerId }?.name ?: ownerId
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    BackHandler(onBack = onClose)
    LaunchedEffect(ownerId) { node.markStoriesSeen(ownerId) }
    LaunchedEffect(stories.size) {
        if (index > stories.lastIndex) index = stories.lastIndex
    }
    LaunchedEffect(current.id, confirmDelete) {
        if (current.kind == "video" || confirmDelete) return@LaunchedEffect
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
                if (mine) {
                    IconButton(onClick = { confirmDelete = true }) {
                        Icon(Icons.Outlined.Delete, "Delete story", tint = Color.White)
                    }
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, "Close", tint = Color.White)
                }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this story?") },
            text = { Text("It will be removed from your stories and from people who already received it.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDelete = false
                        scope.launch { runCatching { node.deleteFeed(current.id) } }
                    },
                ) { Text("Delete", color = Ink.danger) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun ProfilePosts(
    node: DirectNode,
    state: NodeState,
    ownerId: String,
    canAdd: Boolean,
    showHeading: Boolean = true,
    onError: (String?) -> Unit,
    onOpenMedia: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val posts = profilePosts(state, ownerId)
    var draft by remember { mutableStateOf<FeedDraft?>(null) }
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
                draft = FeedDraft(kind, prepared.mime, prepared.name, prepared.bytes)
                onError(null)
            } catch (error: Exception) {
                onError(error.message ?: "That post was not added.")
            }
        }
    }
    Column(Modifier.fillMaxWidth()) {
        if (showHeading || canAdd) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (showHeading) Label("Photos and videos") else Spacer(Modifier.weight(1f))
                if (canAdd) {
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
                                Modifier.weight(1f).aspectRatio(1f).padding(1.dp).clickable(onClickLabel = "View full size") { onOpenMedia(item.id) },
                            )
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f).aspectRatio(1f)) }
                    }
                }
            }
        }
    }
    draft?.let { next ->
        FeedComposer(node, state, next, onDismiss = { draft = null }, onError = onError)
    }
}

@Composable
internal fun SavedPosts(
    node: DirectNode,
    state: NodeState,
    onOpenMedia: (String) -> Unit,
    showHeading: Boolean = true,
) {
    val posts = savedFeed(state)
    Column(Modifier.fillMaxWidth()) {
        if (showHeading) Label("Saved")
        if (posts.isEmpty()) {
            Muted("Save a post and it stays here.", Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
        } else {
            Column(Modifier.fillMaxWidth().padding(horizontal = 1.dp)) {
                posts.chunked(3).forEach { row ->
                    Row(Modifier.fillMaxWidth()) {
                        row.forEach { item ->
                            FeedThumb(
                                node,
                                item,
                                Modifier.weight(1f).aspectRatio(1f).padding(1.dp).clickable(onClickLabel = "View full size") { onOpenMedia(item.id) },
                            )
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f).aspectRatio(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
internal fun ContactProfileScreen(
    node: DirectNode,
    state: NodeState,
    peerId: String,
    back: () -> Unit,
    onMessage: () -> Unit = {},
    onOpenMedia: (String) -> Unit,
) {
    val contact = state.contacts.firstOrNull { it.directId == peerId }
    val self = peerId == state.profile?.directId
    val name = if (self) state.profile?.name ?: "You" else contact?.name ?: peerId
    val jpeg = if (self) state.profile?.avatarJpegBase64 else contact?.avatarJpegBase64
    val about = if (self) state.profile?.status.orEmpty() else contact?.about.orEmpty()
    val stories = liveStories(state, peerId)
    val canCall = !self && contact?.accepted == true && contact.blocked != true
    var storyOpen by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmBlock by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val placeCall = rememberPlaceCall(node, peerId) { error = it }
    BackHandler(onBack = back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground) }
            Title(name)
        }
        ProfileIdentityHeader(
            name = name,
            jpeg = jpegBytes(jpeg),
            status = about,
            posts = profilePosts(state, peerId).size,
            contacts = if (self) state.contacts.count { it.accepted && !it.blocked } else null,
            stories = stories.isNotEmpty(),
            unseenStories = stories.any { !it.seen },
            onAvatar = if (stories.isNotEmpty()) {{ storyOpen = true }} else null,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        if (!self) {
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    onClick = onMessage,
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Ink.accent, contentColor = Color.White),
                    contentPadding = PaddingValues(horizontal = 16.dp),
                    modifier = Modifier.weight(1f).height(40.dp),
                ) {
                    Icon(Icons.Outlined.Chat, null, modifier = Modifier.padding(end = 8.dp).size(18.dp))
                    Text("Message", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                }
                if (canCall) {
                    ProfileIconButton(Icons.Filled.Call, "Call") { placeCall(false) }
                    ProfileIconButton(Icons.Filled.Videocam, "Video") { placeCall(true) }
                }
            }
            if (contact != null) {
                if (contact.blocked) {
                    Muted(
                        "You blocked this person. Messages from them are dropped.",
                        Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp),
                    )
                    OutlinedButton(
                        onClick = { scope.launch { runCatching { node.unblock(peerId) }.onFailure { error = it.message } } },
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, Ink.border),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Ink.accent),
                        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp).height(40.dp),
                    ) {
                        Text("Unblock", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    }
                } else {
                    OutlinedButton(
                        onClick = { confirmBlock = true },
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, Ink.danger),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Ink.danger),
                        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp).height(40.dp),
                    ) {
                        Text("Block", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    }
                }
            }
        }
        error?.let { Text(it, color = Ink.danger, modifier = Modifier.padding(horizontal = 20.dp)) }
        if (contact?.blocked != true) {
            ProfilePosts(node, state, peerId, canAdd = self, onError = { error = it }, onOpenMedia = onOpenMedia)
        }
    }
    if (confirmBlock) {
        AlertDialog(
            onDismissRequest = { confirmBlock = false },
            title = { Text("Block $name?") },
            text = { Text("They won’t be able to message you. Existing chats stay on this phone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmBlock = false
                        scope.launch { runCatching { node.block(peerId) }.onFailure { error = it.message } }
                    },
                ) { Text("Block", color = Ink.danger) }
            },
            dismissButton = { TextButton(onClick = { confirmBlock = false }) { Text("Cancel") } },
        )
    }
    if (storyOpen) StoryViewer(node, state, peerId) { storyOpen = false }
}

@Composable
internal fun ProfileIdentityHeader(
    name: String,
    jpeg: ByteArray?,
    status: String,
    posts: Int,
    contacts: Int? = null,
    stories: Boolean = false,
    unseenStories: Boolean = false,
    onAvatar: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(Modifier.clickable(enabled = onAvatar != null) { onAvatar?.invoke() }) {
            if (stories) {
                Box(Modifier.size(94.dp), contentAlignment = Alignment.Center) {
                    StoryRing(unseenStories)
                    Avatar(name, jpeg, 82.dp)
                }
            } else {
                Avatar(name, jpeg, 88.dp)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(name, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            if (status.isNotBlank()) Text(status, color = Ink.muted, fontSize = 14.sp)
            Row(
                Modifier.padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                ProfileCount(posts, if (posts == 1) "post" else "posts")
                if (contacts != null) ProfileCount(contacts, if (contacts == 1) "contact" else "contacts")
            }
        }
    }
}

@Composable
private fun ProfileCount(value: Int, label: String) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text("$value", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        Text(label, color = Ink.muted, fontSize = 12.sp)
    }
}

@Composable
private fun ProfileIconButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, Ink.border),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Ink.accent),
        contentPadding = PaddingValues(0.dp),
        modifier = Modifier.size(40.dp),
    ) {
        Icon(icon, label, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun FeedThumb(node: DirectNode, item: FeedItem, modifier: Modifier) {
    var bitmap by remember(item.id, item.mediaFile) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    LaunchedEffect(item.id, item.mediaFile) {
        val bytes = node.readFeed(item.id) ?: return@LaunchedEffect
        bitmap = withContext(Dispatchers.Default) {
            feedPoster(bytes, item.kind)?.asImageBitmap()
        }
    }
    Box(modifier.background(Ink.accentSoft), contentAlignment = Alignment.Center) {
        if (bitmap != null) {
            Image(bitmap!!, item.name, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Box(Modifier.fillMaxSize().background(Ink.accentSoft))
        }
        if (item.kind == "video") {
            Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }
    }
}

@Composable
internal fun FeedPostViewer(
    node: DirectNode,
    state: NodeState,
    viewingId: String?,
    canDelete: Boolean,
    onClose: () -> Unit,
    onOpenMedia: () -> Unit,
    onError: (String?) -> Unit,
) {
    val item = viewingId?.let { id -> state.feed.firstOrNull { it.id == id } }
    LaunchedEffect(viewingId, item == null) {
        if (viewingId != null && item == null) onClose()
    }
    if (item == null) return
    val scope = rememberCoroutineScope()
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
        onOpenMedia = onOpenMedia,
        onError = onError,
    )
}

@Composable
private fun FeedActions(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    onOpenComments: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val selfId = state.profile?.directId
    val mine = item.likes.firstOrNull { it.fromId == selfId }?.emoji
    var picking by remember { mutableStateOf(false) }
    var forwarding by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(start = 6.dp, end = 8.dp, top = 2.dp)) {
        if (picking) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ChatNotes.EMOJIS.forEach { emoji ->
                    Text(
                        emoji,
                        fontSize = 22.sp,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(if (mine == emoji) Ink.accent.copy(alpha = 0.16f) else Color.Transparent)
                            .clickable {
                                picking = false
                                scope.launch { runCatching { node.reactFeed(item.id, emoji) } }
                            }
                            .padding(horizontal = 6.dp, vertical = 8.dp),
                    )
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { picking = !picking }) {
                if (mine != null) {
                    Text(mine, fontSize = 20.sp)
                } else {
                    Icon(Icons.Outlined.FavoriteBorder, "React", tint = Ink.foreground, modifier = Modifier.size(24.dp))
                }
            }
            IconButton(onClick = onOpenComments) {
                Icon(Icons.Outlined.ChatBubbleOutline, "Comments", tint = Ink.foreground, modifier = Modifier.size(24.dp))
            }
            IconButton(onClick = { forwarding = true }) {
                Icon(Icons.Outlined.Share, "Forward", tint = Ink.foreground, modifier = Modifier.size(24.dp))
            }
            Spacer(Modifier.weight(1f))
            val saved = item.id in state.savedPosts
            IconButton(onClick = { scope.launch { runCatching { node.saveFeed(item.id) } } }) {
                Icon(
                    if (saved) Icons.Filled.Bookmark else Icons.Outlined.BookmarkBorder,
                    if (saved) "Saved" else "Save",
                    tint = if (saved) Ink.accent else Ink.foreground,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
        if (item.likes.isNotEmpty()) {
            Row(
                Modifier.padding(start = 8.dp, end = 8.dp, bottom = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                item.likes.groupBy { it.emoji }.forEach { (emoji, people) ->
                    val selected = people.any { it.fromId == selfId }
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (selected) Ink.accent.copy(alpha = 0.16f) else Ink.background)
                            .clickable { scope.launch { runCatching { node.reactFeed(item.id, emoji) } } }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(emoji, fontSize = 14.sp)
                        if (people.size > 1) Text("${people.size}", fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
    }
    if (forwarding) {
        ForwardSheet(state, onDismiss = { forwarding = false }) { target ->
            forwarding = false
            scope.launch { runCatching { node.forwardFeed(item.id, target) } }
        }
    }
}

@Composable
private fun CommentRow(
    state: NodeState,
    fromId: String,
    body: String,
    createdAt: Long,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val name = feedOwnerName(state, fromId)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        Avatar(name, jpegBytes(feedOwnerJpeg(state, fromId)), if (compact) 24.dp else 32.dp)
        Column(Modifier.weight(1f)) {
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(name) }
                    append("  ")
                    append(body)
                },
                fontSize = if (compact) 13.sp else 14.sp,
                lineHeight = if (compact) 18.sp else 20.sp,
            )
            Text(formatFeedTime(createdAt), color = Ink.muted, fontSize = 11.sp, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

@Composable
private fun CommentComposer(
    state: NodeState,
    draft: String,
    onDraft: (String) -> Unit,
    onSend: () -> Unit,
) {
    val focus = LocalFocusManager.current
    val self = state.profile
    val ready = draft.isNotBlank()
    fun send() {
        if (!ready) return
        onSend()
        focus.clearFocus()
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Avatar(self?.name ?: "You", jpegBytes(self?.avatarJpegBase64), 32.dp)
        OutlinedTextField(
            value = draft,
            onValueChange = { onDraft(it.take(FeedNotes.MAX_COMMENT)) },
            modifier = Modifier.weight(1f),
            placeholder = { Text("Add a comment…", color = Ink.muted, fontSize = 15.sp) },
            singleLine = true,
            shape = RoundedCornerShape(24.dp),
            textStyle = TextStyle(fontSize = 15.sp, color = Ink.foreground),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { send() }),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Ink.accent,
                unfocusedBorderColor = Ink.border,
                focusedContainerColor = Ink.background,
                unfocusedContainerColor = Ink.background,
            ),
        )
        Text(
            "Post",
            color = if (ready) Ink.accent else Ink.muted,
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(enabled = ready, onClick = { send() })
                .padding(horizontal = 8.dp, vertical = 10.dp),
        )
    }
}

@Composable
internal fun FeedLightbox(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    canDelete: Boolean,
    onDelete: () -> Unit,
    onClose: () -> Unit,
    onOpenMedia: () -> Unit,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var draft by rememberSaveable(item.id) { mutableStateOf("") }
    var localError by remember { mutableStateOf<String?>(null) }
    val name = feedOwnerName(state, item.ownerId)
    val comments = rememberLazyListState()
    LaunchedEffect(item.comments.size) {
        if (item.comments.isNotEmpty()) comments.scrollToItem(item.comments.lastIndex)
    }
    BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(Color.Black).imePadding()) {
        Box(Modifier.fillMaxWidth().height(240.dp).background(Color.Black)) {
            FeedMedia(node, item, Modifier.fillMaxSize())
            if (item.kind != "video") {
                Box(Modifier.matchParentSize().clickable(onClickLabel = "View full size", onClick = onOpenMedia))
            }
            Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
                if (canDelete) {
                    IconButton(onClick = onDelete) { Icon(Icons.Outlined.Delete, "Delete", tint = Color.White) }
                }
            }
            IconButton(onClick = onOpenMedia, modifier = Modifier.align(Alignment.BottomEnd)) {
                Box(
                    Modifier.size(36.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Fullscreen, "View full size", tint = Color.White, modifier = Modifier.size(18.dp))
                }
            }
        }
        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(Ink.surface),
        ) {
            Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(width = 36.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(Ink.border))
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Avatar(name, jpegBytes(feedOwnerJpeg(state, item.ownerId)), 36.dp)
                Column(Modifier.weight(1f)) {
                    Text(name, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                    Text(formatFeedTime(item.createdAt), color = Ink.muted, fontSize = 12.sp)
                }
            }
            FeedActions(node, state, item, onOpenComments = {})
            if (item.caption.isNotBlank()) {
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(name) }
                        append("  ")
                        append(item.caption)
                    },
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                    fontSize = 14.sp,
                )
            }
            if (item.tags.isNotEmpty()) {
                Text(
                    feedTaggedLine(state, item.tags),
                    color = Ink.muted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 2.dp),
                )
            }
            HorizontalDivider(color = Ink.border, modifier = Modifier.padding(top = 8.dp))
            if (item.comments.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth().padding(14.dp), contentAlignment = Alignment.TopStart) {
                    Text("No comments yet. Say something.", color = Ink.muted, fontSize = 14.sp)
                }
            } else {
                LazyColumn(
                    state = comments,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(item.comments, key = { it.id }) { comment ->
                        CommentRow(state, comment.fromId, comment.body, comment.createdAt)
                    }
                }
            }
            localError?.let { Text(it, color = Ink.danger, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) }
            HorizontalDivider(color = Ink.border)
            CommentComposer(state, draft, { draft = it }) {
                val body = draft
                scope.launch {
                    try {
                        node.commentFeed(item.id, body)
                        draft = ""
                        localError = null
                        onError(null)
                    } catch (error: Exception) {
                        val message = error.message ?: "That comment was not saved."
                        localError = message
                        onError(message)
                    }
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
                    isFocusable = false
                    isFocusableInTouchMode = false
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

private class FeedDraft(val kind: String, val mime: String, val name: String, val bytes: ByteArray)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FeedComposer(
    node: DirectNode,
    state: NodeState,
    draft: FeedDraft,
    onDismiss: () -> Unit,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var caption by remember { mutableStateOf("") }
    var tagged by remember { mutableStateOf(setOf<String>()) }
    var poster by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    val contacts = state.contacts.filter { it.accepted && !it.blocked }.sortedBy { it.name.lowercase() }
    LaunchedEffect(draft) {
        poster = withContext(Dispatchers.Default) {
            feedPoster(draft.bytes, draft.kind)?.asImageBitmap()
        }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.94f)
                .padding(12.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(Ink.background)
                .imePadding(),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Text(
                    "New post",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                TextButton(
                    onClick = {
                        scope.launch {
                            try {
                                node.publishFeed(
                                    FeedNotes.POST,
                                    draft.kind,
                                    draft.mime,
                                    draft.name,
                                    draft.bytes,
                                    caption,
                                    tagged.toList(),
                                )
                                onError(null)
                                onDismiss()
                            } catch (error: Exception) {
                                onError(error.message ?: "That post was not added.")
                            }
                        }
                    },
                ) { Text("Share") }
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .aspectRatio(1f)
                        .clip(RoundedCornerShape(16.dp))
                        .background(Ink.accentSoft),
                    contentAlignment = Alignment.Center,
                ) {
                    poster?.let {
                        Image(it, draft.name, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    }
                    if (draft.kind == "video") {
                        Box(
                            Modifier.size(48.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(28.dp))
                        }
                    }
                }
                OutlinedTextField(
                    value = caption,
                    onValueChange = { caption = it.take(FeedNotes.MAX_CAPTION) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Quote or description") },
                    placeholder = { Text("Add a quote or description") },
                    minLines = 3,
                    maxLines = 6,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Ink.accent,
                        unfocusedBorderColor = Ink.border,
                    ),
                    supportingText = { Text("${caption.length}/${FeedNotes.MAX_CAPTION}") },
                )
                if (contacts.isNotEmpty()) {
                    Text("Tag contacts", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                    Text("Tagged people show up on the post.", color = Ink.muted, fontSize = 13.sp)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        contacts.forEach { contact ->
                            val on = contact.directId in tagged
                            Text(
                                contact.name,
                                color = if (on) Color.White else Ink.foreground,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(20.dp))
                                    .background(if (on) Ink.accent else Ink.accentSoft)
                                    .clickable {
                                        tagged = if (on) tagged - contact.directId
                                        else if (tagged.size < FeedNotes.MAX_TAGS) tagged + contact.directId
                                        else tagged
                                    }
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
