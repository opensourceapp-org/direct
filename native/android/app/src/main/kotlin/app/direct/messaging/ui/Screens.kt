package app.direct.messaging.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.direct.core.delivery.MessageState
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.core.store.Direction
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
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        when {
            !state.ready -> Centered("Opening DIRECT")
            state.storageError != null -> Centered(state.storageError!!)
            state.profile == null -> Onboarding(node)
            else -> Home(node, state)
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
private fun Home(node: DirectNode, state: NodeState) {
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
                Tab.IDENTITY -> IdentityScreen(node, state)
            }
        }
        NavigationBar(containerColor = Ink.background, tonalElevation = 0.dp) {
            Tab.entries.forEach { item ->
                NavigationBarItem(
                    selected = tab == item,
                    onClick = { tab = item },
                    icon = {},
                    label = { Text(item.label, fontWeight = if (tab == item) FontWeight.SemiBold else FontWeight.Normal) },
                    colors = NavigationBarItemDefaults.colors(indicatorColor = Ink.surface, selectedTextColor = Ink.foreground, unselectedTextColor = Ink.muted),
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
                val outgoing = message.direction == Direction.OUTGOING
                Column(Modifier.fillMaxWidth(), horizontalAlignment = if (outgoing) Alignment.End else Alignment.Start) {
                    Text(
                        message.body,
                        color = if (outgoing) androidx.compose.ui.graphics.Color.White else Ink.foreground,
                        modifier = Modifier
                            .widthIn(max = 300.dp)
                            .background(if (outgoing) Ink.foreground else Ink.surface, RoundedCornerShape(12.dp))
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                    val state0 = message.state
                    if (outgoing && state0 != null) {
                        Text(
                            state0.label(),
                            fontSize = 12.sp,
                            color = if (state0 == MessageState.FAILED) Ink.danger else Ink.muted,
                            modifier = Modifier.padding(top = 2.dp).clickable(enabled = state0 == MessageState.FAILED) {
                                scope.attempt({ error = it }) { node.retry(message.id) }
                            },
                        )
                    }
                }
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
            else -> Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f)) { Field(draft, { draft = it }, "Message", singleLine = false) }
                Text(
                    "Send",
                    fontWeight = FontWeight.SemiBold,
                    color = if (draft.isBlank()) Ink.muted else Ink.foreground,
                    modifier = Modifier.clickable(enabled = draft.isNotBlank()) {
                        val body = draft
                        draft = ""
                        scope.attempt({ error = it }) { node.send(peerId, body) }
                    }.padding(8.dp),
                )
            }
        }
    }
}

@Composable
private fun ContactsScreen(node: DirectNode, state: NodeState, open: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var directId by rememberSaveable { mutableStateOf("") }
    var bundle by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("People", "Contacts")
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Muted("Look up a DIRECT ID from a phone that has DIRECT open on the same bootstrap address. The phones can be on different networks.")
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
            SecondaryButton("Verify and add", enabled = bundle.isNotBlank()) {
                scope.attempt({ error = it }) {
                    node.addContactBundle(bundle)
                    bundle = ""
                }
            }
            error?.let { Text(it, color = Ink.danger, fontSize = 14.sp) }
        }
        Spacer(Modifier.padding(8.dp))
        state.contacts.filter { it.accepted && !it.blocked }.forEach { contact ->
            Column(Modifier.fillMaxWidth().clickable { open(contact.directId) }.padding(horizontal = 20.dp, vertical = 12.dp)) {
                Label(contact.name)
                Mono(contact.directId)
                Muted(if (contact.verified) "Verified · ${contact.fingerprint}" else "Not verified · ${contact.fingerprint}")
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
private fun IdentityScreen(node: DirectNode, state: NodeState) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val profile = state.profile ?: return
    var phrase by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("This phone", profile.name)
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("DIRECT ID")
            Mono(profile.directId)
            SecondaryButton("Copy DIRECT ID") { copy(context, "DIRECT ID", profile.directId) }
            state.bundle?.let { bundle -> SecondaryButton("Copy identity bundle") { copy(context, "DIRECT bundle", bundle) } }
            Muted("Device ${profile.deviceId}")
            Label("Recovery phrase")
            Muted("Anyone with these 24 words can become you. Write them down and keep them off this phone.")
            val shown = phrase
            if (shown == null) SecondaryButton("Show recovery phrase") { scope.launch { phrase = node.recoveryPhrase() } }
            else {
                Mono(shown)
                SecondaryButton("Hide") { phrase = null }
            }
        }
    }
}

private fun copy(context: Context, label: String, text: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, text))
}
