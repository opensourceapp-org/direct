package app.direct.messaging.ui

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DynamicFeed
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Chat
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material.icons.outlined.Gif
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.DynamicFeed
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.QrCode
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material.icons.outlined.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.graphics.BitmapFactory
import app.direct.core.Encoding
import app.direct.core.delivery.MessageState
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.core.signaling.BootstrapUrl
import app.direct.core.protocol.ChatNotes
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileCards
import app.direct.core.store.Direction
import app.direct.core.store.MessageRecord
import app.direct.core.store.Profile
import app.direct.messaging.DirectApp
import app.direct.messaging.platform.MessageAlerts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class Tab(val label: String, val icon: ImageVector, val selectedIcon: ImageVector) {
    CHATS("Chats", Icons.Outlined.Chat, Icons.Filled.Chat),
    CONTACTS("Contacts", Icons.Outlined.Group, Icons.Filled.Group),
    FEED("Feed", Icons.Outlined.DynamicFeed, Icons.Filled.DynamicFeed),
    PROFILE("Profile", Icons.Outlined.Person, Icons.Filled.Person),
}

private fun CoroutineScope.attempt(onError: (String?) -> Unit, block: suspend () -> Unit) = launch {
    onError(null)
    try {
        block()
    } catch (error: Exception) {
        onError(error.message ?: "Something went wrong.")
    }
}

@Composable
fun DirectRoot(node: DirectNode) {
    val state by node.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("direct.ui", Context.MODE_PRIVATE) }
    var introSeen by remember { mutableStateOf(prefs.getBoolean("intro.seen", false)) }
    var replayIntro by rememberSaveable { mutableStateOf(false) }
    fun finishIntro() {
        prefs.edit().putBoolean("intro.seen", true).apply()
        introSeen = true
        replayIntro = false
    }
    Box(Modifier.fillMaxSize().safeDrawingPadding().dismissKeyboardOnOutsideTap()) {
        when {
            !state.ready -> Centered("Opening DIRECT")
            state.storageError != null -> Centered(state.storageError!!)
            replayIntro || (state.profile == null && !introSeen) -> Intro(creating = state.profile == null, onDone = ::finishIntro)
            state.profile == null -> Onboarding(node)
            else -> Home(node, state) { replayIntro = true }
        }
        state.call?.let { CallOverlay(node, state, it) }
    }
}

@Composable
private fun Centered(text: String) = Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) { Muted(text) }

@Composable
private fun Onboarding(node: DirectNode) {
    val scope = rememberCoroutineScope()
    var name by rememberSaveable { mutableStateOf("") }
    var phrase by rememberSaveable { mutableStateOf("") }
    var restoring by rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Spacer(Modifier.padding(top = 32.dp))
        Box(Modifier.size(72.dp).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Lock, null, tint = Ink.accent, modifier = Modifier.size(32.dp))
        }
        Text("DIRECT", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp, color = Ink.accent)
        Title("No middlemen. Just connection.")
        Muted("Your identity is created on this phone and its keys stay in the Android Keystore. There is no account and no server that stores your messages.")
        Label("Display name")
        Field(name, { name = it.take(32) }, "Ada")
        if (restoring) {
            Label("Recovery phrase")
            Field(phrase, { phrase = it }, "24 words", singleLine = false, minLines = 3)
            PrimaryButton("Restore identity", enabled = name.isNotBlank() && phrase.isNotBlank()) {
                scope.attempt({ error = it }) { node.restoreIdentity(phrase, name) }
            }
            SecondaryButton("Create a new identity instead") { restoring = false }
        } else {
            PrimaryButton("Create identity", enabled = name.isNotBlank()) {
                scope.attempt({ error = it }) { node.createIdentity(name) }
            }
            SecondaryButton("Restore from recovery phrase", Icons.Outlined.Key) { restoring = true }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
    }
}

@Composable
private fun Home(node: DirectNode, state: NodeState, onHowItWorks: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DirectApp
    val pending by app.openPeer.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(Tab.CHATS) }
    var openPeer by rememberSaveable { mutableStateOf<String?>(null) }
    var newGroup by rememberSaveable { mutableStateOf(false) }
    var storyOwner by rememberSaveable { mutableStateOf<String?>(null) }
    var profilePeer by rememberSaveable { mutableStateOf<String?>(null) }
    var viewingId by rememberSaveable { mutableStateOf<String?>(null) }
    var viewingCanDelete by rememberSaveable { mutableStateOf(false) }
    var mediaId by rememberSaveable { mutableStateOf<String?>(null) }
    var mediaCanDelete by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(pending) {
        val target = pending ?: return@LaunchedEffect
        openPeer = target
        newGroup = false
        app.consumeOpenPeer()
    }
    LaunchedEffect(openPeer) {
        openPeer?.let { MessageAlerts.cancel(context, it) }
    }
    val peer = openPeer
    if (peer != null) {
        BackHandler { openPeer = null }
        ChatScreen(node, state, peer) { openPeer = null }
        return
    }
    if (newGroup) {
        BackHandler { newGroup = false }
        NewGroupScreen(node, state, back = { newGroup = false }) { openPeer = it; newGroup = false }
        return
    }
    val media = mediaId?.let { id -> state.feed.firstOrNull { it.id == id } }
    if (mediaId != null) {
        if (media == null) {
            LaunchedEffect(mediaId) { mediaId = null }
        } else {
            FeedMediaViewer(
                node, state, media, canDelete = mediaCanDelete,
                onClose = { mediaId = null },
                onError = {},
            )
        }
        return
    }
    if (viewingId != null) {
        FeedPostViewer(
            node, state, viewingId, canDelete = viewingCanDelete,
            onClose = { viewingId = null },
            onOpenMedia = {
                mediaId = viewingId
                mediaCanDelete = viewingCanDelete
            },
            onError = {},
        )
        return
    }
    val profile = profilePeer
    if (profile != null) {
        ContactProfileScreen(
            node, state, profile,
            back = { profilePeer = null },
            onMessage = {
                openPeer = profile
                profilePeer = null
            },
        ) { id ->
            mediaId = id
            mediaCanDelete = profile == state.profile?.directId
        }
        return
    }
    val story = storyOwner
    if (story != null) {
        StoryViewer(node, state, story) { storyOwner = null }
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            when (tab) {
                Tab.CHATS -> ChatsScreen(state, onNewGroup = { newGroup = true }) { openPeer = it }
                Tab.CONTACTS -> ContactsScreen(node, state) { openPeer = it }
                Tab.FEED -> FeedScreen(
                    node, state,
                    onOpenStory = { storyOwner = it },
                    onOpenProfile = { profilePeer = it },
                    onOpenMedia = { mediaId = it; mediaCanDelete = false },
                    onOpenComments = { viewingId = it; viewingCanDelete = false },
                )
                Tab.PROFILE -> IdentityScreen(node, state, onHowItWorks) { id ->
                    mediaId = id
                    mediaCanDelete = state.feed.firstOrNull { it.id == id }?.ownerId == state.profile?.directId
                }
            }
        }
        HorizontalDivider(color = Ink.border)
        NavigationBar(containerColor = Ink.surface, tonalElevation = 0.dp) {
            Tab.entries.forEach { item ->
                val selected = tab == item
                NavigationBarItem(
                    selected = selected,
                    onClick = { tab = item },
                    icon = { Icon(if (selected) item.selectedIcon else item.icon, item.label) },
                    label = { Text(item.label, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal) },
                    colors = NavigationBarItemDefaults.colors(
                        indicatorColor = Ink.accentSoft,
                        selectedIconColor = Ink.accent,
                        unselectedIconColor = Ink.muted,
                        selectedTextColor = Ink.accent,
                        unselectedTextColor = Ink.muted,
                    ),
                )
            }
        }
    }
}

@Composable
internal fun Header(eyebrow: String, title: String) = Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 8.dp)) {
    Text(eyebrow.uppercase(), color = Ink.muted, fontSize = 12.sp, letterSpacing = 1.2.sp)
    Title(title)
}

@Composable
private fun ChatsScreen(state: NodeState, onNewGroup: () -> Unit, open: (String) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Header("Messages", "Chats")
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onNewGroup) {
                Icon(Icons.Outlined.Group, "New group", tint = Ink.accent)
            }
        }
        if (state.conversations.isEmpty()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(72.dp).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Chat, null, tint = Ink.accent, modifier = Modifier.size(32.dp))
                }
                Muted(
                    "No conversations yet. Add a contact by DIRECT ID. A message someone sends you before you add them appears here as a request.",
                    Modifier.padding(top = 16.dp),
                )
            }
            return
        }
        LazyColumn {
            items(state.conversations, key = { it.peerId }) { conversation ->
                Row(
                    Modifier.fillMaxWidth().clickable { open(conversation.peerId) }.padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    val contact = state.contacts.firstOrNull { it.directId == conversation.peerId }
                    Avatar(conversation.name, jpegBytes(contact?.avatarJpegBase64))
                    Column(Modifier.weight(1f)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Label(conversation.name)
                            if (conversation.group) Badge("Group", Ink.accent)
                            if (conversation.request) Badge("Request", Ink.warning)
                        }
                        Muted(conversation.lastBody ?: "No messages yet")
                    }
                    if (conversation.unread > 0) Badge(conversation.unread.toString())
                    if (conversation.peerId in state.connected) Dot(Ink.success) else if (conversation.peerId in state.online) Dot(Ink.warning)
                }
                HorizontalDivider(color = Ink.border)
            }
        }
    }
}

@Composable
private fun Badge(text: String, color: Color = Ink.accent) = Text(
    text,
    color = Color.White,
    fontSize = 12.sp,
    fontWeight = FontWeight.Medium,
    modifier = Modifier.background(color, RoundedCornerShape(10.dp)).padding(horizontal = 8.dp, vertical = 2.dp),
)

@Composable
private fun ChatScreen(node: DirectNode, state: NodeState, peerId: String, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val contact = state.contacts.firstOrNull { it.directId == peerId }
    val group = state.groups.firstOrNull { it.id == peerId }
    val conversation = state.conversations.firstOrNull { it.peerId == peerId }
    val messages = state.messages[peerId].orEmpty()
    val request = contact != null && !contact.accepted && !contact.blocked
    val isGroup = group != null || conversation?.group == true
    var draft by rememberSaveable { mutableStateOf("") }
    var editingId by rememberSaveable { mutableStateOf<String?>(null) }
    var forwarding by remember { mutableStateOf<MessageRecord?>(null) }
    var deleting by remember { mutableStateOf<MessageRecord?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var profileOpen by rememberSaveable { mutableStateOf(false) }
    var viewingId by rememberSaveable { mutableStateOf<String?>(null) }
    var mediaId by rememberSaveable { mutableStateOf<String?>(null) }
    var mediaCanDelete by rememberSaveable { mutableStateOf(false) }
    val list = rememberLazyListState()
    LaunchedEffect(peerId, messages.size, contact?.accepted, isGroup) {
        if (isGroup || contact?.accepted == true) node.openConversation(peerId)
        if (messages.isNotEmpty()) list.animateScrollToItem(messages.lastIndex)
    }
    val status = when {
        isGroup -> "${group?.members?.size ?: conversation?.memberCount ?: 0} members"
        contact == null -> "Not a contact"
        contact.blocked -> "Blocked"
        request -> "Message request"
        peerId in state.connected -> "Connected directly"
        peerId in state.online -> "On the bootstrap"
        else -> "Offline · messages wait on this phone"
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = back),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground)
            }
            Box(Modifier.clickable(enabled = !isGroup && contact != null) { profileOpen = true }) {
                Avatar(contact?.name ?: conversation?.name ?: "?", jpegBytes(contact?.avatarJpegBase64), 40.dp)
            }
            Column(Modifier.weight(1f).padding(start = 12.dp, top = 8.dp, bottom = 8.dp)) {
                Text(
                    contact?.name ?: conversation?.name ?: peerId,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Ink.foreground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(status, fontSize = 13.sp, color = Ink.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (isGroup || (contact?.accepted == true && !contact.blocked)) {
                CallActions(node, peerId) { error = it }
            }
        }
        HorizontalDivider(color = Ink.border)
        LazyColumn(Modifier.weight(1f).padding(horizontal = 16.dp), state = list, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Spacer(Modifier.padding(4.dp)) }
            items(messages, key = { it.id }) { message ->
                MessageBubble(
                    node, state, message, isGroup,
                    onRetry = { scope.attempt({ error = it }) { node.retry(message.id) } },
                    onEdit = {
                        editingId = message.id
                        draft = message.body
                    },
                    onForward = { forwarding = message },
                    onDelete = { deleting = message },
                    onReact = { emoji -> scope.attempt({ error = it }) { node.react(message.id, emoji) } },
                    onOpenPost = { id ->
                        if (state.feed.any { it.id == id }) viewingId = id
                        else error = "That post isn't on this phone."
                    },
                )
            }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 16.dp)) }
        HorizontalDivider(color = Ink.border)
        when {
            isGroup -> Composer(node, peerId, draft, { draft = it }, { error = it }, editingId = editingId, onCancelEdit = { editingId = null; draft = "" })
            contact == null -> Unit
            request -> Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Muted("${contact.name} is not in your contacts. Accept to reply. Decline blocks this DIRECT ID.")
                PrimaryButton("Accept") { scope.attempt({ error = it }) { node.acceptRequest(peerId) } }
                SecondaryButton("Decline") {
                    scope.attempt({ error = it }) {
                        node.declineRequest(peerId)
                        back()
                    }
                }
            }
            contact.blocked -> Muted("You blocked this DIRECT ID.", Modifier.padding(16.dp))
            else -> Composer(node, peerId, draft, { draft = it }, { error = it }, editingId = editingId, onCancelEdit = { editingId = null; draft = "" })
        }
    }
    forwarding?.let { message ->
        ForwardSheet(state, peerId, onDismiss = { forwarding = null }) { target ->
            scope.attempt({ error = it }) {
                node.forwardMessage(message.id, target)
                forwarding = null
            }
        }
    }
    deleting?.let { message ->
        DeleteSheet(
            message = message,
            onDismiss = { deleting = null },
            onDeleteForMe = {
                scope.attempt({ error = it }) {
                    node.deleteMessage(message.id, false)
                    if (editingId == message.id) {
                        editingId = null
                        draft = ""
                    }
                    deleting = null
                }
            },
            onDeleteForEveryone = {
                scope.attempt({ error = it }) {
                    node.deleteMessage(message.id, true)
                    if (editingId == message.id) {
                        editingId = null
                        draft = ""
                    }
                    deleting = null
                }
            },
        )
    }
    if (profileOpen && !isGroup) {
        ContactProfileScreen(
            node, state, peerId,
            back = { profileOpen = false },
            onMessage = { profileOpen = false },
            onOpenMedia = {
                mediaId = it
                mediaCanDelete = peerId == state.profile?.directId
            },
        )
    }
    val media = mediaId?.let { id -> state.feed.firstOrNull { it.id == id } }
    if (media != null) {
        FeedMediaViewer(
            node, state, media, canDelete = mediaCanDelete,
            onClose = { mediaId = null },
            onError = { error = it },
        )
    } else if (mediaId != null) {
        LaunchedEffect(mediaId) { mediaId = null }
    } else if (viewingId != null) {
        FeedPostViewer(
            node, state, viewingId, canDelete = false,
            onClose = { viewingId = null },
            onOpenMedia = {
                mediaId = viewingId
                mediaCanDelete = false
            },
            onError = { error = it },
        )
    }
}

@Composable
private fun NewGroupScreen(node: DirectNode, state: NodeState, back: () -> Unit, opened: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val people = state.contacts.filter { it.accepted && !it.blocked }
    var name by rememberSaveable { mutableStateOf("") }
    var selected by rememberSaveable { mutableStateOf(setOf<String>()) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = back),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground)
            }
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text("New group", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Ink.foreground)
                Text("Pick at least one contact", fontSize = 13.sp, color = Ink.muted)
            }
        }
        HorizontalDivider(color = Ink.border)
        Column(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Label("Group name")
            Field(name, { name = it.take(32) }, "Weekend")
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
            PrimaryButton("Create group", enabled = name.isNotBlank() && selected.isNotEmpty()) {
                scope.attempt({ error = it }) {
                    val group = node.createGroup(name, selected.toList())
                    opened(group.id)
                }
            }
        }
        HorizontalDivider(color = Ink.border)
        if (people.isEmpty()) {
            Muted("Add an accepted contact before you create a group.", Modifier.padding(20.dp))
        } else {
            LazyColumn {
                items(people, key = { it.directId }) { contact ->
                    val on = contact.directId in selected
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            selected = if (on) selected - contact.directId else selected + contact.directId
                        }.padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Avatar(contact.name, jpegBytes(contact.avatarJpegBase64))
                        Column(Modifier.weight(1f)) {
                            Label(contact.name)
                            Mono(contact.directId)
                        }
                        Box(
                            Modifier.size(22.dp).clip(CircleShape).background(if (on) Ink.accent else Color.Transparent)
                                .border(androidx.compose.foundation.BorderStroke(1.dp, if (on) Ink.accent else Ink.border), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (on) Text("✓", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                    HorizontalDivider(color = Ink.border)
                }
            }
        }
    }
}

@Composable
private fun ContactsScreen(node: DirectNode, state: NodeState, open: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var directId by rememberSaveable { mutableStateOf("") }
    var bundle by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var scanning by rememberSaveable { mutableStateOf(false) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) {
            scanning = false
            error = "Camera permission is needed to scan a QR code."
        }
    }
    if (scanning) {
        BackHandler { scanning = false }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            QrScanner(onCode = { text ->
                scanning = false
                scope.attempt({ error = it }) { node.addFromShare(text) }
            }, onClose = { scanning = false })
        } else {
            LaunchedEffect(Unit) { camera.launch(Manifest.permission.CAMERA) }
            Centered("Allow camera access to scan a QR code.")
        }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("People", "Contacts")
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Muted("Looking up a DIRECT ID only works if that person turned on public listing on this server. A scanned QR code also carries that server and saves it on this phone.")
            SecondaryButton("Scan a QR code", Icons.Outlined.QrCodeScanner) { scanning = true }
            Field(directId, { directId = it }, "dir_…")
            PrimaryButton(if (busy) "Looking up" else "Look up", enabled = directId.isNotBlank() && !busy) {
                busy = true
                scope.attempt({ error = it }) {
                    try {
                        val added = node.addContact(directId)
                        directId = ""
                        open(added.directId)
                    } finally {
                        busy = false
                    }
                }
            }
            Label("Or paste an identity bundle")
            Field(bundle, { bundle = it }, "{\"v\":1,…}", singleLine = false, minLines = 3)
            SecondaryButton("Add from bundle or share card", enabled = bundle.isNotBlank()) {
                scope.attempt({ error = it }) {
                    node.addFromShare(bundle)
                    bundle = ""
                }
            }
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
        LaunchedEffect(state.bootstrap.isOpen) {
            if (state.bootstrap.isOpen) node.refreshSuggestions()
        }
        Spacer(Modifier.padding(8.dp))
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Label("Discovery")
            Card {
                Row(
                    Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (state.discoverable) Ink.success.copy(alpha = 0.14f) else Ink.accentSoft),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Outlined.Person,
                            null,
                            tint = if (state.discoverable) Ink.success else Ink.accent,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Let others find you", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        Muted(if (state.discoverable) "Visible on this server" else "Hidden until you share a QR or ID")
                    }
                    Switch(
                        checked = state.discoverable,
                        onCheckedChange = { on -> scope.launch { node.setDiscoverable(on) } },
                        colors = SwitchDefaults.colors(checkedTrackColor = Ink.accent, checkedThumbColor = Color.White),
                    )
                }
            }
            Muted(
                if (state.discoverable) "Other DIRECT phones on this server can look you up and see you here. They still cannot read your messages."
                else "Off by default. Turn this on to appear in suggestions. A QR code or pasted card still works either way.",
            )
        }
        if (state.bootstrap.isOpen) {
            if (state.suggestions.isEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(Ink.border),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Outlined.Person, null, tint = Ink.muted, modifier = Modifier.size(20.dp))
                    }
                    Column {
                        Text("No one else is listed", fontSize = 16.sp, fontWeight = FontWeight.Medium)
                        Muted("When someone turns this on, they show up here to add.")
                    }
                }
            }
            state.suggestions.forEach { person ->
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(person.name.ifBlank { person.directId }, null)
                    Column(Modifier.weight(1f)) {
                        Label(person.name.ifBlank { person.directId })
                        Mono(person.directId)
                    }
                    TextButton(onClick = { scope.attempt({ error = it }) { node.addContactBundle(person.bundle) } }) {
                        Text("Add", color = Ink.accent, fontWeight = FontWeight.SemiBold)
                    }
                }
                HorizontalDivider(color = Ink.border)
            }
        }
        Spacer(Modifier.padding(8.dp))
        Column(Modifier.padding(horizontal = 20.dp)) { Label("Contacts") }
        state.contacts.filter { it.accepted && !it.blocked }.forEach { contact ->
            Row(
                Modifier.fillMaxWidth().clickable { open(contact.directId) }.padding(horizontal = 20.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Avatar(contact.name, jpegBytes(contact.avatarJpegBase64))
                Column(Modifier.weight(1f)) {
                    Label(contact.name)
                    if (contact.about.isNotBlank()) Muted(contact.about)
                    Mono(contact.directId)
                    Muted(if (contact.verified) "Verified · ${contact.fingerprint}" else "Not verified · ${contact.fingerprint}")
                }
            }
            HorizontalDivider(color = Ink.border)
        }
    }
}

@Composable
private fun NetworkScreen(node: DirectNode, state: NodeState) {
    val scope = rememberCoroutineScope()
    var address by rememberSaveable(state.bootstrapUrl) { mutableStateOf(state.bootstrapUrl ?: BootstrapUrl.DEFAULT) }
    var error by remember { mutableStateOf<String?>(null) }
    val (phase, color) = state.bootstrap.describe()
    var help by rememberSaveable { mutableStateOf(false) }
    if (help) {
        BackHandler { help = false }
        ServerHelp { help = false }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 4.dp, top = 12.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("DIAGNOSTICS", color = Ink.muted, fontSize = 12.sp, letterSpacing = 1.2.sp)
                Title("Network")
            }
            IconButton(onClick = { help = true }) {
                Icon(Icons.Outlined.HelpOutline, "How to run your own server", tint = Ink.accent)
            }
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Card {
                StatusRow("Bootstrap", phase, color)
                HorizontalDivider(color = Ink.border)
                StatusRow("Address", state.bootstrapUrl ?: BootstrapUrl.DEFAULT)
                HorizontalDivider(color = Ink.border)
                StatusRow("Network", if (state.networkAvailable) "Available" else "Offline", if (state.networkAvailable) Ink.success else Ink.danger)
                HorizontalDivider(color = Ink.border)
                StatusRow("Contacts online", state.online.size.toString(), if (state.online.isEmpty()) Ink.muted else Ink.success)
                HorizontalDivider(color = Ink.border)
                StatusRow("Direct channels", state.connected.size.toString(), if (state.connected.isEmpty()) Ink.muted else Ink.success)
                HorizontalDivider(color = Ink.border)
                StatusRow("Waiting for a receipt", state.pending.toString())
            }
            state.bootstrap.error?.let { Muted("Last error: $it") }
            Label("Bootstrap address")
            Muted("This phone uses the public DIRECT signaling server unless you save a different address. Both phones must use the same value. It sees public bundles, presence, and WebRTC negotiation. It never receives message text.")
            Field(address, { address = it }, BootstrapUrl.DEFAULT)
            PrimaryButton("Use this bootstrap", enabled = address.isNotBlank()) {
                scope.attempt({ error = it }) { address = node.setBootstrap(address) }
            }
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
    }
}

@Composable
private fun ServerHelp(onClose: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onClose),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground)
            }
            Title("Your server")
        }
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Muted("Phones already use the public DIRECT signaling server. Open Network and you will see that address filled in. Save a different address only if you want both phones on your own server.")
            HelpCode(BootstrapUrl.DEFAULT)
            Muted("To run your own server, download Direct Server for Mac, Windows, or Linux from https://direct-server.apps.grok.bot. Open the app, press Start server, and share the address it shows. Each phone that connects is listed in the window.")
            HelpCode("https://direct-server.apps.grok.bot")
            Muted("To run it from source instead, clone the project. On a Mac, double-click Start Server.command in that folder. Direct.app is the iPhone app. macOS will not open it.")
            HelpCode("git clone https://github.com/opensourceapp-org/direct.git\ncd direct\npnpm install\npnpm server")
            Muted("The server only introduces the two phones. It does not store messages, photos, voice notes, or calls.")
            HelpBlock(
                "What you need",
                "A computer both phones can reach. The download does not need Node.js. From source, you need Node.js 22 or newer, pnpm, and this DIRECT project on that computer.",
            )
            HelpBlock("Start it", "Open Direct Server, or run pnpm server from source. Press Start server. The window shows one address for each network on that computer and lists each phone that connects. Closing the window stops the server. The same server can run in a terminal with pnpm signaling. Leave that terminal open. Use the address your phones are on, for example:")
            HelpCode("ws://192.168.1.20:8787")
            Muted("Allow TCP port 8787 through that computer's firewall. On both phones, open Network, paste that address, and save it. Both phones must save the same address.")
            HelpBlock("Check that it is running", "On the same network, open this page in a browser. Replace the example with the address the window or the terminal showed.")
            HelpCode("http://192.168.1.20:8787/health")
            Muted("A working server answers:")
            HelpCode("{\"ok\":true,\"service\":\"direct-signaling\",\"contract\":1}")
            Muted("The page at the server root is a short note that this is the DIRECT signaling server.")
            HelpCode("http://192.168.1.20:8787")
            HelpBlock("Addresses the phone accepts", "A bare host is saved as ws:// and port 8787. http:// is saved as ws://. https:// is saved as wss://. The host is lowercased, and a trailing slash is removed.")
            HelpCode("ws://192.168.1.20:8787\n192.168.1.20\nhttp://192.168.1.20:8787\nhttps://signals.example.com")
            Muted("Do not enter localhost, 127.0.0.1, or 0.0.0.0. On a phone those names mean the phone itself.")
            HelpBlock("Choose a port", "8787 is the default. The server listens on every network interface of that computer unless you set HOST to one address.")
            HelpCode("PORT=9000 pnpm signaling\nws://192.168.1.20:9000")
            HelpBlock(
                "Phones away from your Wi-Fi",
                "A 192.168 address only works on that local network. Forward TCP 8787 to this computer, or run the server where both phones can reach it, and save that address. This server speaks plain WebSocket and does not add TLS itself. For a public wss:// address, put a TLS proxy in front of port 8787 and save wss://your.host, or https://your.host.",
            )
            HelpBlock(
                "What it is allowed to see",
                "Public identity bundles, who is online, and the WebRTC setup that connects the phones. The message itself stays sealed on the phones.",
            )
        }
    }
}

@Composable
private fun HelpBlock(title: String, body: String) = Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
    Label(title)
    Muted(body)
}

@Composable
private fun HelpCode(text: String) = Text(
    text,
    fontFamily = FontFamily.Monospace,
    fontSize = 13.sp,
    color = Ink.foreground,
    modifier = Modifier.fillMaxWidth().background(Ink.surface, RoundedCornerShape(10.dp)).border(1.dp, Ink.border, RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 10.dp),
)

@Composable
private fun IdentityScreen(node: DirectNode, state: NodeState, onHowItWorks: () -> Unit, onOpenMedia: (String) -> Unit) {
    var pane by rememberSaveable { mutableStateOf("home") }
    when (pane) {
        "edit" -> EditProfileScreen(node, state) { pane = "home" }
        "settings" -> SettingsScreen(node, state, onHowItWorks) { pane = "home" }
        else -> ProfileHomeScreen(node, state, onEdit = { pane = "edit" }, onSettings = { pane = "settings" }, onOpenMedia = onOpenMedia)
    }
}

@Composable
private fun ProfileHomeScreen(
    node: DirectNode,
    state: NodeState,
    onEdit: () -> Unit,
    onSettings: () -> Unit,
    onOpenMedia: (String) -> Unit,
) {
    val profile = state.profile ?: return
    var error by remember { mutableStateOf<String?>(null) }
    val posts = profilePosts(state, profile.directId)
    val stories = liveStories(state, profile.directId)
    val people = state.contacts.count { it.accepted && !it.blocked }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 4.dp, top = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Title("Profile")
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onSettings) {
                Icon(Icons.Outlined.Settings, "Settings", tint = Ink.foreground)
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Avatar(profile.name, jpegBytes(profile.avatarJpegBase64), 88.dp)
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.SpaceEvenly) {
                ProfileStat("${posts.size}", "Posts")
                ProfileStat("$people", "Contacts")
                ProfileStat("${stories.size}", "Stories")
            }
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(profile.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            if (profile.status.isNotBlank()) Text(profile.status, fontSize = 14.sp)
            SecondaryButton("Edit profile") { onEdit() }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) }
        ProfilePosts(node, state, profile.directId, canAdd = true, showHeading = false, onError = { error = it }, onOpenMedia = onOpenMedia)
        SavedPosts(node, state, onOpenMedia)
    }
}

@Composable
private fun EditProfileScreen(node: DirectNode, state: NodeState, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val profile = state.profile ?: return
    var status by rememberSaveable(profile.status) { mutableStateOf(profile.status) }
    var error by remember { mutableStateOf<String?>(null) }
    var acknowledged by remember { mutableStateOf<String?>(null) }
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            error = null
            try {
                node.setAvatar(MediaPrep.avatar(context, uri))
            } catch (exception: Exception) {
                error = exception.message ?: "That photo could not be used."
            }
        }
    }
    val statusDraft = status.trim()
    BackHandler(onBack = back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground) }
            Title("Edit profile")
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Avatar(profile.name, jpegBytes(profile.avatarJpegBase64), 72.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SecondaryButton("Change photo", Icons.Outlined.PhotoCamera) {
                        photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    }
                    if (profile.avatarJpegBase64 != null) {
                        SecondaryButton("Remove photo", Icons.Outlined.Delete) {
                            scope.attempt({ error = it }) { node.clearAvatar() }
                        }
                    }
                }
            }
            Label("Status")
            Field(status, { status = it.take(80) }, "Write your own status")
            PrimaryButton(if (acknowledged == statusDraft) "Saved" else "Save status") {
                scope.attempt({ error = it }) {
                    node.setStatus(status)
                    acknowledged = status.trim()
                }
            }
            if (acknowledged == statusDraft) {
                Text(
                    if (statusDraft.isEmpty()) "Status cleared" else "Status saved",
                    color = Ink.success,
                    fontWeight = FontWeight.Medium,
                )
            }
            StatusMenu(selected = statusPresets.firstOrNull { it == profile.status }) { preset ->
                status = preset
                scope.attempt({ error = it }) {
                    node.setStatus(preset)
                    acknowledged = preset
                }
            }
            Muted("Choose one, or write your own and tap Save status.")
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
    }
}

@Composable
private fun SettingsScreen(node: DirectNode, state: NodeState, onHowItWorks: () -> Unit, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val profile = state.profile ?: return
    var phrase by remember { mutableStateOf<String?>(null) }
    var showQr by rememberSaveable { mutableStateOf(false) }
    var showNetwork by rememberSaveable { mutableStateOf(false) }
    val bundle = state.bundle
    val server = state.bootstrapUrl.orEmpty()
    val card = bundle?.let { shareCard(profile, it, server) }
    if (showNetwork) {
        BackHandler { showNetwork = false }
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { showNetwork = false }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground)
                }
            }
            Box(Modifier.weight(1f)) { NetworkScreen(node, state) }
        }
        return
    }
    BackHandler(onBack = back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Ink.foreground) }
            Title("Settings")
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("Share")
            Mono(profile.directId)
            SecondaryButton("Copy DIRECT ID", Icons.Outlined.ContentCopy) { copy(context, "DIRECT ID", profile.directId) }
            if (card != null) {
                SecondaryButton(if (showQr) "Hide QR code" else "Show QR code", Icons.Outlined.QrCode) { showQr = !showQr }
                if (showQr) {
                    Card {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            QrImage(card, Modifier.fillMaxWidth())
                            Muted(
                                if (server.isEmpty()) "Set the server under Network before sharing. Without that address, the other phone can save your identity but cannot connect."
                                else "The QR code is your signed identity and your server address, plus the status and a small photo. Scanning it saves that server so the two phones can connect.",
                            )
                        }
                    }
                }
                SecondaryButton("Share profile", Icons.Outlined.Share) { shareProfile(context, profile, card, server) }
            }
            state.bundle?.let { raw -> SecondaryButton("Copy identity bundle", Icons.Outlined.ContentCopy) { copy(context, "DIRECT bundle", raw) } }
            Label("Connection")
            SecondaryButton("Network", Icons.Outlined.WifiTethering) { showNetwork = true }
            Muted("Bootstrap address, connection status, and how to run your own server.")
            SecondaryButton("How DIRECT works", Icons.Outlined.Info) { onHowItWorks() }
            Muted("Device ${profile.deviceId}")
            Label("Recovery")
            Muted("Anyone with these 24 words can become you. Write them down and keep them off this phone.")
            val shown = phrase
            if (shown == null) SecondaryButton("Show recovery phrase", Icons.Outlined.Key) { scope.launch { phrase = node.recoveryPhrase() } }
            else {
                Mono(shown)
                SecondaryButton("Hide") { phrase = null }
            }
        }
    }
}

@Composable
private fun ProfileStat(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Text(label, color = Ink.muted, fontSize = 12.sp)
    }
}

@Composable
private fun Composer(
    node: DirectNode,
    peerId: String,
    draft: String,
    onDraft: (String) -> Unit,
    onError: (String?) -> Unit,
    attachments: Boolean = true,
    editingId: String? = null,
    onCancelEdit: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var attach by rememberSaveable { mutableStateOf(false) }
    var stickers by rememberSaveable { mutableStateOf(false) }
    var recording by remember { mutableStateOf(false) }
    var wave by remember { mutableStateOf(List(24) { 0.18f }) }
    var elapsed by remember { mutableStateOf(0L) }
    val voice = remember { VoiceCapture(context) }
    val stickersArt = remember {
        (0 until MediaPrep.STICKER_COUNT).map { index ->
            val prepared = MediaPrep.sticker(index)
            prepared to BitmapFactory.decodeByteArray(prepared.bytes, 0, prepared.bytes.size)
        }
    }
    LaunchedEffect(recording) {
        if (!recording) {
            wave = List(24) { 0.18f }
            elapsed = 0L
            return@LaunchedEffect
        }
        while (true) {
            voice.sample()
            val next = voice.waveform()
            wave = if (next.isEmpty()) List(24) { 0.18f } else next
            elapsed = voice.elapsedMs()
            delay(80)
        }
    }
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) sendPrepared(scope, node, peerId, onDraft, draft, onError) { MediaPrep.visual(context, uri) }
    }
    val video = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) sendPrepared(scope, node, peerId, onDraft, draft, onError) { MediaPrep.video(context, uri) }
    }
    val gif = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) sendPrepared(scope, node, peerId, onDraft, draft, onError) { MediaPrep.gif(context, uri) }
    }
    val mic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) onError("Microphone permission is needed for a voice message.")
        else {
            try {
                voice.start()
                recording = true
                onError(null)
            } catch (exception: Exception) {
                onError(exception.message ?: "Recording could not start.")
            }
        }
    }
    Column(Modifier.background(Ink.surface).padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (editingId != null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Editing message", color = Ink.accent, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                Text("Cancel", color = Ink.muted, fontSize = 13.sp, modifier = Modifier.clickable(onClick = onCancelEdit))
            }
        }
        if (attachments && stickers && editingId == null) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                stickersArt.forEach { (prepared, bitmap) ->
                    if (bitmap != null) {
                        Image(
                            bitmap.asImageBitmap(),
                            "Sticker",
                            Modifier.size(72.dp).clickable {
                                stickers = false
                                attach = false
                                sendPrepared(scope, node, peerId, onDraft, draft, onError) { prepared }
                            },
                            contentScale = ContentScale.Fit,
                        )
                    }
                }
            }
        }
        if (attachments && attach && !recording && editingId == null) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                AttachChoice(Icons.Outlined.Image, "Photo") { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                AttachChoice(Icons.Outlined.Videocam, "Video") { video.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) }
                AttachChoice(Icons.Outlined.Gif, "GIF") { gif.launch("image/gif") }
                AttachChoice(Icons.Outlined.EmojiEmotions, "Sticker") { stickers = !stickers }
                AttachChoice(Icons.Filled.Mic, "Voice") {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        try {
                            voice.start()
                            recording = true
                        } catch (exception: Exception) {
                            onError(exception.message ?: "Recording could not start.")
                        }
                    } else mic.launch(Manifest.permission.RECORD_AUDIO)
                }
            }
        }
        if (recording) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                RoundIcon(Icons.Outlined.Delete, Color.Transparent, Ink.danger, "Cancel recording") {
                    voice.cancel()
                    recording = false
                }
                VoiceWave(wave, 1f, Ink.success, Ink.success.copy(alpha = 0.35f), Modifier.weight(1f))
                Text(voiceClock(elapsed), color = Ink.foreground, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                RoundIcon(Icons.AutoMirrored.Filled.Send, Ink.accent, Color.White, "Send voice") {
                    val recorded = try {
                        voice.stop()
                    } catch (exception: Exception) {
                        voice.cancel()
                        recording = false
                        onError(exception.message ?: "That recording is empty.")
                        return@RoundIcon
                    }
                    recording = false
                    sendPrepared(scope, node, peerId, onDraft, draft, onError) { Prepared("audio", "audio/mp4", "voice.m4a", recorded) }
                }
            }
        } else {
            val canSend = draft.isNotBlank()
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (attachments && editingId == null) {
                    RoundIcon(
                        if (attach) Icons.Filled.Close else Icons.Filled.Add,
                        Ink.accentSoft,
                        Ink.accent,
                        if (attach) "Close attachments" else "Add attachment",
                    ) {
                        attach = !attach
                        if (!attach) stickers = false
                    }
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraft,
                    textStyle = TextStyle(color = Ink.foreground, fontSize = 16.sp),
                    cursorBrush = SolidColor(Ink.accent),
                    maxLines = 5,
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 44.dp)
                                .background(Ink.surface, RoundedCornerShape(22.dp))
                                .border(androidx.compose.foundation.BorderStroke(1.dp, Ink.border), RoundedCornerShape(22.dp))
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            if (draft.isEmpty()) Text("Message", color = Ink.muted, fontSize = 16.sp)
                            inner()
                        }
                    },
                )
                RoundIcon(
                    Icons.AutoMirrored.Filled.Send,
                    if (canSend) Ink.accent else Ink.border,
                    if (canSend) Color.White else Ink.muted,
                    if (editingId != null) "Save" else "Send",
                ) {
                    if (!canSend) return@RoundIcon
                    val body = draft
                    val editId = editingId
                    onDraft("")
                    attach = false
                    if (editId != null) {
                        onCancelEdit()
                        scope.attempt(onError) { node.editMessage(editId, body) }
                    } else {
                        scope.attempt(onError) { node.send(peerId, body) }
                    }
                }
            }
        }
    }
}

@Composable
private fun VoiceWave(levels: List<Float>, progress: Float, played: Color, idle: Color, modifier: Modifier = Modifier) {
    val bars = if (levels.isEmpty()) List(24) { 0.2f } else levels
    Canvas(modifier.height(28.dp)) {
        val count = bars.size
        val barWidth = 3.dp.toPx()
        val spacing = if (count > 1) ((size.width - count * barWidth) / (count - 1)).coerceAtLeast(2.dp.toPx()) else 0f
        val used = count * barWidth + (count - 1) * spacing
        var x = ((size.width - used) / 2f).coerceAtLeast(0f)
        bars.forEachIndexed { index, level ->
            val barHeight = (4.dp.toPx() + (size.height - 4.dp.toPx()) * level).coerceIn(4.dp.toPx(), size.height)
            val reached = count <= 1 || index.toFloat() / (count - 1) <= progress
            drawRoundRect(
                color = if (reached) played else idle,
                topLeft = Offset(x, (size.height - barHeight) / 2f),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(barWidth / 2f, barWidth / 2f),
            )
            x += barWidth + spacing
        }
    }
}

@Composable
private fun VoiceNote(bytes: ByteArray, outgoing: Boolean) {
    var peaks by remember(bytes) { mutableStateOf(List(28) { 0.22f }) }
    var playing by remember(bytes) { mutableStateOf(false) }
    var progress by remember(bytes) { mutableStateOf(0f) }
    var duration by remember(bytes) { mutableStateOf(0) }
    var position by remember(bytes) { mutableStateOf(0) }
    val context = LocalContext.current
    val player = remember(bytes) { VoiceNotePlayer(context, bytes) { playing = false; progress = 0f; position = 0 } }
    DisposableEffect(player) { onDispose { player.release() } }
    LaunchedEffect(bytes) {
        peaks = withContext(Dispatchers.Default) { VoiceWaveform.peaks(bytes).toList() }
        duration = player.duration()
    }
    LaunchedEffect(playing) {
        while (playing) {
            if (!player.isPlaying()) {
                playing = false
                progress = 0f
                position = 0
                break
            }
            position = player.position()
            val length = player.duration().coerceAtLeast(duration)
            duration = length
            progress = if (length > 0) position.toFloat() / length else 0f
            delay(50)
        }
    }
    val played = if (outgoing) Color.White else Ink.success
    val idle = if (outgoing) Color.White.copy(alpha = 0.35f) else Ink.foreground.copy(alpha = 0.28f)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier.size(32.dp).clip(CircleShape).background(if (outgoing) Color.White else Ink.success).clickable {
                if (playing) {
                    player.pause()
                    playing = false
                } else {
                    player.play()
                    playing = true
                }
            },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                if (playing) "Pause" else "Play",
                tint = if (outgoing) Ink.accent else Color.White,
                modifier = Modifier.size(18.dp),
            )
        }
        VoiceWave(peaks, if (playing || progress > 0f) progress else 0f, played, idle, Modifier.weight(1f).widthIn(min = 96.dp))
        Text(
            voiceClock(if (position > 0) position.toLong() else duration.toLong()),
            color = if (outgoing) Color.White.copy(alpha = 0.9f) else Ink.muted,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, background: Color, tint: Color, description: String, onClick: () -> Unit) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).background(background).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, description, tint = tint, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun AttachChoice(icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(
        Modifier.clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(52.dp).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = Ink.accent)
        }
        Text(label, fontSize = 12.sp, color = Ink.foreground)
    }
}

private fun sendPrepared(
    scope: kotlinx.coroutines.CoroutineScope,
    node: DirectNode,
    peerId: String,
    onDraft: (String) -> Unit,
    draft: String,
    onError: (String?) -> Unit,
    prepare: () -> Prepared,
) {
    scope.launch {
        onError(null)
        try {
            val prepared = prepare()
            node.sendMedia(peerId, prepared.kind, prepared.mime, prepared.name, prepared.bytes, draft.trim())
            onDraft("")
        } catch (exception: Exception) {
            onError(exception.message ?: "That attachment was not sent.")
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
private fun MessageBubble(
    node: DirectNode,
    state: NodeState,
    message: MessageRecord,
    group: Boolean,
    onRetry: () -> Unit,
    onEdit: () -> Unit,
    onForward: () -> Unit,
    onDelete: () -> Unit,
    onReact: (String) -> Unit,
    onOpenPost: (String) -> Unit,
) {
    val outgoing = message.direction == Direction.OUTGOING
    val context = LocalContext.current
    val sender = message.senderId?.let { id -> state.contacts.firstOrNull { it.directId == id }?.name ?: id }
    var bytes by remember(message.id, message.mediaFile) { mutableStateOf<ByteArray?>(null) }
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(message.id, message.mediaFile) {
        bytes = message.mediaFile?.let { node.readMedia(message.id) }
    }
    val kind = message.mediaKind
    val sticker = kind == "sticker"
    val actionable = kind != "call" && kind != "group"
    val ink = if (outgoing) Color.White else Ink.foreground
    val hasReactions = message.reactions.isNotEmpty() && !message.deleted
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (outgoing) Alignment.End else Alignment.Start) {
        if (group && !outgoing && sender != null) {
            Text(sender, fontSize = 12.sp, color = Ink.muted, modifier = Modifier.padding(start = 4.dp, bottom = 2.dp))
        }
        Box(Modifier.padding(bottom = if (hasReactions) 16.dp else 0.dp)) {
            Column(
                Modifier
                    .widthIn(min = if (kind == "audio") 220.dp else 0.dp, max = 280.dp)
                    .then(
                        if ((sticker && !message.deleted) || (message.feedPostId != null && !message.deleted)) Modifier
                        else Modifier
                            .background(if (outgoing) Ink.accent else Ink.surface, RoundedCornerShape(20.dp))
                            .border(androidx.compose.foundation.BorderStroke(1.dp, if (outgoing) Ink.accent else Ink.border), RoundedCornerShape(20.dp))
                            .padding(8.dp),
                    )
                    .padding(bottom = if (hasReactions) 14.dp else 0.dp)
                    .combinedClickable(
                        onClick = {
                            message.feedPostId?.let(onOpenPost)
                                ?: run { if (outgoing && message.state == MessageState.FAILED) onRetry() }
                        },
                        onLongClick = { if (actionable) menu = true },
                    ),
            ) {
                if (message.deleted) {
                    Text("This message was deleted", color = ink.copy(alpha = 0.8f), fontStyle = FontStyle.Italic, modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
                } else if (message.feedPostId != null) {
                    SharedPostCard(state, message, bytes)
                } else {
                    if (message.forwarded) {
                        Text("Forwarded", fontSize = 12.sp, color = ink.copy(alpha = 0.72f), modifier = Modifier.padding(horizontal = 4.dp))
                    }
                    val picture = if (kind == "image" || kind == "gif" || sticker) {
                        bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    } else null
                    if (picture != null) {
                        Image(
                            picture.asImageBitmap(),
                            MediaNotes.label(kind) ?: "Attachment",
                            if (sticker) Modifier.size(148.dp) else Modifier.fillMaxWidth().heightIn(max = 220.dp).clip(RoundedCornerShape(12.dp)),
                            contentScale = if (sticker) ContentScale.Fit else ContentScale.Crop,
                        )
                    }
                    val label = MediaNotes.label(kind)
                    val caption = message.body.isNotBlank() && message.body != label
                    if (kind == "audio") {
                        if (bytes != null) VoiceNote(bytes!!, outgoing)
                        else VoiceWave(emptyList(), 0f, if (outgoing) Color.White else Ink.success, if (outgoing) Color.White.copy(alpha = 0.35f) else Ink.foreground.copy(alpha = 0.28f), Modifier.fillMaxWidth())
                    }
                    if (caption || (picture == null && kind != "audio")) {
                        if (message.body.isNotBlank()) {
                            Text(message.body, color = ink, modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
                        }
                    }
                    if (kind == "video" && bytes != null) {
                        Text(
                            "Open",
                            color = if (outgoing) Color.White else Ink.accent,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(4.dp).clickable { openAttachment(context, bytes!!, message.mediaMime ?: "*/*", message.id, kind) },
                        )
                    }
                    if (message.edited) {
                        Text("Edited", fontSize = 11.sp, color = ink.copy(alpha = 0.7f), modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = 2.dp))
                    }
                }
            }
            if (hasReactions) {
                val selfId = state.profile?.directId
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .align(if (outgoing) Alignment.BottomEnd else Alignment.BottomStart)
                        .padding(horizontal = 8.dp)
                        .wrapContentWidth(if (outgoing) Alignment.End else Alignment.Start)
                        .widthIn(max = 264.dp),
                ) {
                    message.reactions.groupBy { it.emoji }.forEach { (emoji, people) ->
                        val mine = people.any { it.fromId == selfId }
                        ReactionChip(emoji, people.size, mine) { onReact(emoji) }
                    }
                }
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, modifier = Modifier.width(320.dp)) {
                if (!message.deleted) {
                    Row(
                        Modifier.width(308.dp).padding(horizontal = 4.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ChatNotes.EMOJIS.forEach { emoji ->
                            Box(
                                Modifier
                                    .size(width = 36.dp, height = 48.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .clickable {
                                        menu = false
                                        onReact(emoji)
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(emoji, fontSize = 22.sp, textAlign = TextAlign.Center)
                            }
                        }
                    }
                    HorizontalDivider(color = Ink.border)
                }
                if (!message.deleted && outgoing && kind == null) {
                    DropdownMenuItem(text = { Text("Edit") }, onClick = { menu = false; onEdit() })
                }
                if (!message.deleted) {
                    DropdownMenuItem(text = { Text("Forward") }, onClick = { menu = false; onForward() })
                }
                DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
            }
        }
        val state0 = message.state
        if (outgoing && state0 != null && !message.deleted) {
            Text(
                state0.label(),
                fontSize = 12.sp,
                color = if (state0 == MessageState.FAILED) Ink.danger else Ink.muted,
                modifier = Modifier.padding(top = 2.dp).clickable(enabled = state0 == MessageState.FAILED, onClick = onRetry),
            )
        }
    }
}

@Composable
private fun SharedPostCard(
    state: NodeState,
    message: MessageRecord,
    bytes: ByteArray?,
) {
    val owner = message.feedOwnerId?.let { feedOwnerName(state, it) } ?: "Post"
    val picture = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
    Column(horizontalAlignment = if (message.direction == Direction.OUTGOING) Alignment.End else Alignment.Start) {
        Text("Shared post", fontSize = 12.sp, color = Ink.muted, modifier = Modifier.padding(start = 4.dp, end = 4.dp, bottom = 4.dp))
        Column(
            Modifier
                .width(220.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(Ink.surface)
                .border(androidx.compose.foundation.BorderStroke(1.dp, Ink.border), RoundedCornerShape(16.dp)),
        ) {
            Box(
                Modifier.fillMaxWidth().height(220.dp).background(Ink.background),
                contentAlignment = Alignment.Center,
            ) {
                if (picture != null) {
                    Image(
                        picture.asImageBitmap(),
                        "Post",
                        Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                }
                if (message.mediaKind == "video") {
                    Box(
                        Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(22.dp))
                    }
                }
            }
            Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Outlined.DynamicFeed, null, tint = Ink.muted, modifier = Modifier.size(14.dp))
                    Text("Post", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Ink.muted)
                    Spacer(Modifier.weight(1f))
                    Text("Open", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = Ink.accent)
                }
                Text(owner, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (message.body.isNotBlank()) {
                    Text(message.body, fontSize = 13.sp, color = Ink.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun ReactionChip(emoji: String, count: Int, mine: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .height(28.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (mine) Ink.accentSoft else Ink.surface)
            .border(androidx.compose.foundation.BorderStroke(1.dp, if (mine) Ink.accent else Ink.border), RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(emoji, fontSize = 14.sp, lineHeight = 16.sp)
        if (count > 1) Text(count.toString(), fontSize = 12.sp, fontWeight = FontWeight.Medium, color = Ink.foreground, lineHeight = 16.sp)
    }
}

@Composable
internal fun ForwardSheet(state: NodeState, fromPeerId: String = "", onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val targets = state.conversations.filter { it.peerId != fromPeerId && !it.request && !it.blocked }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Forward to") },
        text = {
            if (targets.isEmpty()) {
                Text("Add another contact or group first.", color = Ink.muted)
            } else {
                Column(Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    targets.forEach { conversation ->
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { onPick(conversation.peerId) }.padding(vertical = 10.dp, horizontal = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Avatar(conversation.name, null, 36.dp)
                            Column {
                                Text(conversation.name, color = Ink.foreground, fontWeight = FontWeight.Medium)
                                if (conversation.group) Text("${conversation.memberCount} members", color = Ink.muted, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun DeleteSheet(
    message: MessageRecord,
    onDismiss: () -> Unit,
    onDeleteForMe: () -> Unit,
    onDeleteForEveryone: () -> Unit,
) {
    val everyone = message.direction == Direction.OUTGOING && !message.deleted && message.mediaKind != "call" && message.mediaKind != "group"
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete message") },
        text = { Text(if (everyone) "Remove it on this phone, or for everyone who still has it." else "Remove this message on this phone.") },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                TextButton(onClick = onDeleteForMe) { Text("Delete for me") }
                if (everyone) TextButton(onClick = onDeleteForEveryone) { Text("Delete for everyone") }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun Avatar(name: String, jpeg: ByteArray?, size: Dp = 44.dp) {
    val bitmap = remember(jpeg) { jpeg?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }?.asImageBitmap() }
    Box(Modifier.size(size).clip(CircleShape).background(Ink.accentSoft), contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Text(name.trim().take(1).uppercase().ifBlank { "?" }, color = Ink.accent, fontWeight = FontWeight.SemiBold)
    }
}

private fun jpegBytes(encoded: String?): ByteArray? = encoded?.let { runCatching { Encoding.fromBase64Url(it) }.getOrNull() }

private fun shareCard(profile: Profile, bundle: String, bootstrap: String): String {
    val photo = MediaPrep.qrAvatar(jpegBytes(profile.avatarJpegBase64))
    val withPhoto = ProfileCards.encode(bundle, profile.status, photo, bootstrap)
    return if (photo != null && qrBitmap(withPhoto) == null) ProfileCards.encode(bundle, profile.status, null, bootstrap) else withPhoto
}

private fun copy(context: Context, label: String, text: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, text))
}

private val statusPresets = listOf(
    "😊 Available",
    "🔴 Busy",
    "📚 At school",
    "🎬 At the movies",
    "💼 At work",
    "🔋 Battery about to die",
    "📵 Can't talk, messages only",
    "📅 In a meeting",
    "🏋️ At the gym",
    "😴 Sleeping",
    "🚨 Urgent calls only",
)

@Composable
private fun StatusMenu(selected: String?, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    var menuWidth by remember { mutableStateOf(0.dp) }
    val density = LocalDensity.current
    Box(Modifier.fillMaxWidth().onSizeChanged { menuWidth = with(density) { it.width.toDp() } }) {
        OutlinedTextField(
            value = selected.orEmpty(),
            onValueChange = {},
            readOnly = true,
            placeholder = { Text("Choose a status", color = Ink.muted) },
            trailingIcon = { Icon(Icons.Filled.KeyboardArrowDown, null, tint = Ink.muted) },
            shape = RoundedCornerShape(16.dp),
            textStyle = TextStyle(fontSize = 16.sp, color = Ink.foreground),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Ink.foreground,
                unfocusedBorderColor = Ink.border,
                focusedContainerColor = Ink.surface,
                unfocusedContainerColor = Ink.surface,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        Box(Modifier.matchParentSize().clickable { expanded = true })
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.width(menuWidth)) {
            statusPresets.forEach { preset ->
                DropdownMenuItem(
                    text = { Text(preset, color = if (preset == selected) Ink.accent else Ink.foreground) },
                    onClick = {
                        expanded = false
                        onSelect(preset)
                    },
                )
            }
        }
    }
}
