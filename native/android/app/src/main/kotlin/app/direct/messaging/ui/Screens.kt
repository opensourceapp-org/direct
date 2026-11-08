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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
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
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileCards
import app.direct.core.store.Direction
import app.direct.core.store.MessageRecord
import app.direct.core.store.Profile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private enum class Tab(val label: String) { CHATS("Chats"), CONTACTS("Contacts"), NETWORK("Network"), IDENTITY("Identity") }

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
    Box(Modifier.fillMaxSize().safeDrawingPadding().hideKeyboardOnScroll()) {
        when {
            !state.ready -> Centered("Opening DIRECT")
            state.storageError != null -> Centered(state.storageError!!)
            replayIntro || (state.profile == null && !introSeen) -> Intro(creating = state.profile == null, onDone = ::finishIntro)
            state.profile == null -> Onboarding(node)
            else -> Home(node, state) { replayIntro = true }
        }
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
        Text("DIRECT", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp)
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
            SecondaryButton("Restore from recovery phrase") { restoring = true }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
    }
}

@Composable
private fun Home(node: DirectNode, state: NodeState, onHowItWorks: () -> Unit) {
    var tab by rememberSaveable { mutableStateOf(Tab.CHATS) }
    var openPeer by rememberSaveable { mutableStateOf<String?>(null) }
    val peer = openPeer
    if (peer != null) {
        BackHandler { openPeer = null }
        ChatScreen(node, state, peer) { openPeer = null }
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            when (tab) {
                Tab.CHATS -> ChatsScreen(state) { openPeer = it }
                Tab.CONTACTS -> ContactsScreen(node, state) { openPeer = it }
                Tab.NETWORK -> NetworkScreen(node, state)
                Tab.IDENTITY -> IdentityScreen(node, state, onHowItWorks)
            }
        }
        NavigationBar(containerColor = Ink.background, tonalElevation = 0.dp) {
            Tab.entries.forEach { item ->
                NavigationBarItem(
                    selected = tab == item,
                    onClick = { tab = item },
                    icon = {},
                    label = { Text(item.label, fontWeight = if (tab == item) FontWeight.SemiBold else FontWeight.Normal) },
                    colors = NavigationBarItemDefaults.colors(indicatorColor = Ink.accentSoft, selectedTextColor = Ink.accent, unselectedTextColor = Ink.muted),
                )
            }
        }
    }
}

@Composable
private fun Header(eyebrow: String, title: String) = Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 8.dp)) {
    Text(eyebrow.uppercase(), color = Ink.muted, fontSize = 12.sp, letterSpacing = 1.2.sp)
    Title(title)
}

@Composable
private fun ChatsScreen(state: NodeState, open: (String) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Header("Messages", "Chats")
        if (state.conversations.isEmpty()) {
            Muted("No conversations yet. Add a contact by DIRECT ID. A message someone sends you before you add them appears here as a request.", Modifier.padding(20.dp))
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
                            if (conversation.request) Badge("Request")
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
private fun Badge(text: String) = Text(
    text,
    fontSize = 12.sp,
    fontWeight = FontWeight.Medium,
    modifier = Modifier.background(Ink.surface, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
)

@Composable
private fun ChatScreen(node: DirectNode, state: NodeState, peerId: String, back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val contact = state.contacts.firstOrNull { it.directId == peerId }
    val messages = state.messages[peerId].orEmpty()
    val request = contact != null && !contact.accepted && !contact.blocked
    var draft by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val list = rememberLazyListState()
    LaunchedEffect(peerId, messages.size, contact?.accepted) {
        if (contact?.accepted == true) node.openConversation(peerId)
        if (messages.isNotEmpty()) list.animateScrollToItem(messages.lastIndex)
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Back", modifier = Modifier.clickable(onClick = back).padding(8.dp), fontWeight = FontWeight.Medium)
            Avatar(contact?.name ?: "?", jpegBytes(contact?.avatarJpegBase64), 36.dp)
            Column(Modifier.weight(1f).padding(start = 8.dp)) {
                Label(contact?.name ?: peerId)
                val status = when {
                    contact == null -> "Not a contact"
                    contact.blocked -> "Blocked"
                    request -> "Message request"
                    peerId in state.connected -> "Connected directly"
                    peerId in state.online -> "On the bootstrap"
                    else -> "Offline · messages wait on this phone"
                }
                Muted(status)
            }
        }
        HorizontalDivider(color = Ink.border)
        LazyColumn(Modifier.weight(1f).padding(horizontal = 16.dp), state = list, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { Spacer(Modifier.padding(4.dp)) }
            items(messages, key = { it.id }) { message ->
                MessageBubble(node, message) { scope.attempt({ error = it }) { node.retry(message.id) } }
            }
        }
        error?.let { Text(it, color = Ink.danger, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 16.dp)) }
        HorizontalDivider(color = Ink.border)
        when {
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
            else -> Composer(node, peerId, draft, { draft = it }) { error = it }
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
            Muted("Look up a DIRECT ID from a phone that has DIRECT open on the same server. A scanned QR code also carries that server and saves it on this phone.")
            SecondaryButton("Scan a QR code") { scanning = true }
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
        Spacer(Modifier.padding(8.dp))
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
    var address by rememberSaveable(state.bootstrapUrl) { mutableStateOf(state.bootstrapUrl ?: "") }
    var error by remember { mutableStateOf<String?>(null) }
    val (phase, color) = state.bootstrap.describe()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("Diagnostics", "Network")
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Card {
                StatusRow("Bootstrap", phase, color)
                HorizontalDivider(color = Ink.border)
                StatusRow("Address", state.bootstrapUrl ?: "Not set")
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
            Muted("Both phones must use the same address. Run the signaling server on a computer both phones can reach, then enter it here, for example ws://192.168.1.20:8787. It sees public bundles, presence, and WebRTC negotiation. It never receives message text.")
            Field(address, { address = it }, "ws://192.168.1.20:8787")
            PrimaryButton("Use this bootstrap", enabled = address.isNotBlank()) {
                scope.attempt({ error = it }) { address = node.setBootstrap(address) }
            }
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
    }
}

@Composable
private fun IdentityScreen(node: DirectNode, state: NodeState, onHowItWorks: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val profile = state.profile ?: return
    var phrase by remember { mutableStateOf<String?>(null) }
    var status by rememberSaveable(profile.status) { mutableStateOf(profile.status) }
    var error by remember { mutableStateOf<String?>(null) }
    var showQr by rememberSaveable { mutableStateOf(false) }
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
    val bundle = state.bundle
    val server = state.bootstrapUrl.orEmpty()
    val card = bundle?.let { shareCard(profile, it, server) }
    val statusDraft = status.trim()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("This phone", profile.name)
        if (profile.status.isNotBlank()) {
            Text(profile.status, modifier = Modifier.padding(horizontal = 20.dp), fontSize = 16.sp)
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Avatar(profile.name, jpegBytes(profile.avatarJpegBase64), 72.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SecondaryButton("Profile photo") { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                    if (profile.avatarJpegBase64 != null) SecondaryButton("Remove photo") { scope.attempt({ error = it }) { node.clearAvatar() } }
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
            statusPresets.forEach { preset ->
                StatusChoice(preset, selected = profile.status == preset) {
                    status = preset
                    scope.attempt({ error = it }) {
                        node.setStatus(preset)
                        acknowledged = preset
                    }
                }
            }
            Muted("Choose one, or write your own and tap Save status.")
            Label("DIRECT ID")
            Mono(profile.directId)
            SecondaryButton("Copy DIRECT ID") { copy(context, "DIRECT ID", profile.directId) }
            if (card != null) {
                SecondaryButton(if (showQr) "Hide QR code" else "Show QR code") { showQr = !showQr }
                if (showQr) {
                    Card {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            QrImage(card, Modifier.fillMaxWidth())
                            Muted(
                                if (server.isEmpty()) "Set the server under Network before sharing. Without that address, the other phone can save your identity but cannot connect."
                                else "The QR code is your signed identity and your server address, plus the status and a small photo. Scanning it saves that server so the two phones can connect. The status and photo are for display. They are not part of the signature.",
                            )
                        }
                    }
                }
                SecondaryButton("Share profile") { shareProfile(context, profile, card, server) }
                Muted(
                    if (server.isEmpty()) "Share includes your name and DIRECT ID. Set the server under Network first, or the other phone will not know where to connect."
                    else "Share sends a picture of your QR code, with your name, DIRECT ID, and server address. Scanning it saves that server on the other phone.",
                )
            }
            state.bundle?.let { raw -> SecondaryButton("Copy identity bundle") { copy(context, "DIRECT bundle", raw) } }
            SecondaryButton("How DIRECT works") { onHowItWorks() }
            Muted("Device ${profile.deviceId}")
            Label("Recovery phrase")
            Muted("Anyone with these 24 words can become you. Write them down and keep them off this phone.")
            val shown = phrase
            if (shown == null) SecondaryButton("Show recovery phrase") { scope.launch { phrase = node.recoveryPhrase() } }
            else {
                Mono(shown)
                SecondaryButton("Hide") { phrase = null }
            }
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
    }
}

@Composable
private fun Composer(node: DirectNode, peerId: String, draft: String, onDraft: (String) -> Unit, onError: (String?) -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var attach by rememberSaveable { mutableStateOf(false) }
    var stickers by rememberSaveable { mutableStateOf(false) }
    var recording by remember { mutableStateOf(false) }
    val voice = remember { VoiceCapture(context) }
    val stickersArt = remember {
        (0 until 6).map { index ->
            val prepared = MediaPrep.sticker(index)
            prepared to BitmapFactory.decodeByteArray(prepared.bytes, 0, prepared.bytes.size)
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
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (stickers) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                stickersArt.forEach { (prepared, bitmap) ->
                    if (bitmap != null) {
                        Image(
                            bitmap.asImageBitmap(),
                            "Sticker",
                            Modifier.size(56.dp).clip(CircleShape).clickable {
                                stickers = false
                                attach = false
                                sendPrepared(scope, node, peerId, onDraft, draft, onError) { prepared }
                            },
                        )
                    }
                }
            }
        }
        if (attach && !recording) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Photo", modifier = chip { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, fontWeight = FontWeight.Medium)
                Text("Video", modifier = chip { video.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) }, fontWeight = FontWeight.Medium)
                Text("GIF", modifier = chip { gif.launch("image/gif") }, fontWeight = FontWeight.Medium)
                Text("Sticker", modifier = chip { stickers = !stickers }, fontWeight = FontWeight.Medium)
                Text("Voice", modifier = chip {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        try {
                            voice.start()
                            recording = true
                        } catch (exception: Exception) {
                            onError(exception.message ?: "Recording could not start.")
                        }
                    } else mic.launch(Manifest.permission.RECORD_AUDIO)
                }, fontWeight = FontWeight.Medium)
            }
        }
        if (recording) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Muted("Recording")
                Text("Stop and send", fontWeight = FontWeight.SemiBold, color = Ink.accent, modifier = Modifier.clickable {
                    recording = false
                    sendPrepared(scope, node, peerId, onDraft, draft, onError) { Prepared("audio", "audio/mp4", "voice.m4a", voice.stop()) }
                }.padding(8.dp))
                Text("Cancel", color = Ink.muted, modifier = Modifier.clickable {
                    recording = false
                    voice.cancel()
                }.padding(8.dp))
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("+", fontSize = 22.sp, fontWeight = FontWeight.Medium, color = Ink.accent, modifier = Modifier.clickable { attach = !attach; if (!attach) stickers = false }.padding(8.dp))
                Box(Modifier.weight(1f)) { Field(draft, onDraft, "Message", singleLine = false) }
                Text(
                    "Send",
                    fontWeight = FontWeight.SemiBold,
                    color = if (draft.isBlank()) Ink.muted else Ink.accent,
                    modifier = Modifier.clickable(enabled = draft.isNotBlank()) {
                        val body = draft
                        onDraft("")
                        scope.attempt(onError) { node.send(peerId, body) }
                    }.padding(8.dp),
                )
            }
        }
    }
}

private fun chip(onClick: () -> Unit) = Modifier
    .clip(RoundedCornerShape(20.dp))
    .background(Ink.accentSoft)
    .clickable(onClick = onClick)
    .padding(horizontal = 12.dp, vertical = 8.dp)

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

@Composable
private fun MessageBubble(node: DirectNode, message: MessageRecord, onRetry: () -> Unit) {
    val outgoing = message.direction == Direction.OUTGOING
    val context = LocalContext.current
    var bytes by remember(message.id, message.mediaFile) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(message.id, message.mediaFile) {
        bytes = message.mediaFile?.let { node.readMedia(message.id) }
    }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (outgoing) Alignment.End else Alignment.Start) {
        Column(
            Modifier
                .widthIn(max = 280.dp)
                .background(if (outgoing) Ink.foreground else Color.White, RoundedCornerShape(16.dp))
                .border(androidx.compose.foundation.BorderStroke(1.dp, if (outgoing) Ink.foreground else Ink.border), RoundedCornerShape(16.dp))
                .padding(8.dp),
        ) {
            val kind = message.mediaKind
            val picture = if (kind == "image" || kind == "gif" || kind == "sticker") {
                bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            } else null
            if (picture != null) {
                Image(
                    picture.asImageBitmap(),
                    MediaNotes.label(kind) ?: "Attachment",
                    Modifier.fillMaxWidth().heightIn(max = 220.dp).clip(RoundedCornerShape(12.dp)),
                    contentScale = ContentScale.Crop,
                )
            }
            val label = MediaNotes.label(kind)
            val caption = message.body.isNotBlank() && message.body != label
            if (caption || picture == null) {
                if (message.body.isNotBlank()) {
                    Text(message.body, color = if (outgoing) Color.White else Ink.foreground, modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
                }
            }
            if ((kind == "video" || kind == "audio") && bytes != null) {
                Text(
                    "Open",
                    color = if (outgoing) Color.White else Ink.accent,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(4.dp).clickable { openAttachment(context, bytes!!, message.mediaMime ?: "*/*", message.id, kind) },
                )
            }
        }
        val state0 = message.state
        if (outgoing && state0 != null) {
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
private fun Avatar(name: String, jpeg: ByteArray?, size: Dp = 44.dp) {
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
private fun StatusChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .border(1.dp, if (selected) Ink.accent else Ink.border, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, modifier = Modifier.weight(1f), fontSize = 16.sp)
        if (selected) Text("✓", color = Ink.accent, fontWeight = FontWeight.SemiBold)
    }
}
