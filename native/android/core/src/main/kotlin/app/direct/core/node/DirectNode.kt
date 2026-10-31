package app.direct.core.node

import app.direct.core.Encoding
import app.direct.core.crypto.Bundles
import app.direct.core.crypto.DirectIds
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.PublicBundle
import app.direct.core.delivery.DeliveryEngine
import app.direct.core.delivery.DeliveryRejected
import app.direct.core.protocol.Envelopes
import app.direct.core.protocol.MediaNotes
import app.direct.core.protocol.ProfileCards
import app.direct.core.signaling.BootstrapClient
import app.direct.core.signaling.BootstrapStatus
import app.direct.core.signaling.BootstrapUrl
import app.direct.core.signaling.WebSocketFactory
import app.direct.core.store.ContactRecord
import app.direct.core.store.Direction
import app.direct.core.store.IdentityVault
import app.direct.core.store.LocalStore
import app.direct.core.store.MessageRecord
import app.direct.core.store.Profile
import app.direct.core.store.SecretStore
import app.direct.core.transport.PeerListener
import app.direct.core.transport.PeerTransport
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class DirectException(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { NO_IDENTITY, INVALID_ID, SELF, NO_BOOTSTRAP, BOOTSTRAP_OFFLINE, NOT_FOUND, BAD_BUNDLE, NOT_ACCEPTED, BLOCKED, REJECTED, INVALID_BOOTSTRAP }
}

data class Conversation(
    val peerId: String,
    val name: String,
    val lastBody: String?,
    val lastAt: Long,
    val unread: Int,
    /** An unknown sender's message waiting for Accept or Decline. */
    val request: Boolean,
    val blocked: Boolean,
)

data class NodeState(
    val ready: Boolean = false,
    val profile: Profile? = null,
    val bundle: String? = null,
    val bootstrapUrl: String? = null,
    val bootstrap: BootstrapStatus = BootstrapStatus(BootstrapStatus.Phase.NOT_CONFIGURED, null),
    val contacts: List<ContactRecord> = emptyList(),
    val conversations: List<Conversation> = emptyList(),
    val messages: Map<String, List<MessageRecord>> = emptyMap(),
    val online: Set<String> = emptySet(),
    val connected: Set<String> = emptySet(),
    val pending: Int = 0,
    val foreground: Boolean = true,
    val networkAvailable: Boolean = true,
    val storageError: String? = null,
)

/**
 * Everything DIRECT does on one device, with no UI and no platform types.
 * Android and iOS supply the secret store, the WebSocket, and the WebRTC transport.
 * All state changes run on [dispatcher], which must execute one coroutine at a time.
 */
class DirectNode(
    private val secrets: SecretStore,
    private val storeFile: File?,
    private val sockets: WebSocketFactory,
    private val transportFactory: (bootstrap: BootstrapClient, selfId: String, scope: CoroutineScope) -> PeerTransport,
    private val dispatcher: CoroutineDispatcher,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: () -> Double = Math::random,
    private val ttlMs: Long = DeliveryEngine.DEFAULT_TTL_MS,
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val vault = IdentityVault(secrets)
    private val bootstrap = BootstrapClient(scope, sockets)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val _state = MutableStateFlow(NodeState())
    val state: StateFlow<NodeState> = _state

    private var store: LocalStore = LocalStore.inMemory()
    private var keys: IdentityKeys? = null
    private var engine: DeliveryEngine? = null
    private var transport: PeerTransport? = null
    private var loopJob: Job? = null
    private var watchers: List<Job> = emptyList()
    private val online = HashSet<String>()
    private var foreground = true
    private var networkAvailable = true
    private var mediaDir: File? = null

    suspend fun start() = onNode {
        if (_state.value.ready) return@onNode
        val mediaParent = storeFile?.parentFile ?: File(System.getProperty("java.io.tmpdir"))
        mediaDir = File(mediaParent, "direct-media-" + (storeFile?.nameWithoutExtension ?: "memory")).apply { mkdirs() }
        try {
            store = if (storeFile == null) LocalStore.inMemory() else LocalStore.open(storeFile, vault.storageKey())
        } catch (error: Exception) {
            _state.value = _state.value.copy(ready = true, storageError = "The local store could not be opened with this device's key. Nothing was erased.")
            return@onNode
        }
        val loaded = vault.load()
        val profile = store.profile
        if (loaded != null && profile != null && profile.directId == loaded.directId) activate(loaded)
        bootstrap.configure(store.settings.bootstrapUrl)
        bootstrap.start()
        watchers = listOf(
            scope.launch { bootstrap.status.collect { status -> onBootstrapStatus(status) } },
            scope.launch { bootstrap.presence.collect { onPresence(it.directId, it.online) } },
        )
        _state.value = _state.value.copy(ready = true)
        loopJob = scope.launch { runLoop() }
        publish()
    }

    /** Creates a new identity, stores the seed in the platform secret store, and returns the recovery phrase. */
    suspend fun createIdentity(displayName: String): String = onNode {
        val name = cleanName(displayName)
        val (created, phrase) = vault.create()
        store.profile = Profile(name, Encoding.newDeviceId(), created.directId)
        store.save()
        activate(created)
        publish()
        phrase
    }

    suspend fun restoreIdentity(phrase: String, displayName: String) = onNode {
        val name = cleanName(displayName)
        val restored = vault.restore(phrase)
        store.profile = Profile(name, Encoding.newDeviceId(), restored.directId)
        store.save()
        activate(restored)
        publish()
    }

    suspend fun recoveryPhrase(): String? = onNode { vault.recoveryPhrase() }

    /** Normalizes and saves the bootstrap address. Both phones must end up with the same value. */
    suspend fun setBootstrap(input: String): String = onNode {
        when (val result = BootstrapUrl.normalize(input)) {
            is BootstrapUrl.Result.Invalid -> throw DirectException(DirectException.Reason.INVALID_BOOTSTRAP, result.error.message)
            is BootstrapUrl.Result.Ok -> {
                store.settings = store.settings.copy(bootstrapUrl = result.url)
                store.save()
                bootstrap.configure(result.url)
                publish()
                result.url
            }
        }
    }

    suspend fun addContact(input: String): ContactRecord = onNode {
        val self = keys ?: throw DirectException(DirectException.Reason.NO_IDENTITY, "Create your identity first.")
        val directId = DirectIds.normalize(input)
            ?: throw DirectException(DirectException.Reason.INVALID_ID, "A DIRECT ID looks like dir_ followed by 16 letters and numbers.")
        if (directId == self.directId) throw DirectException(DirectException.Reason.SELF, "This DIRECT ID belongs to this phone.")
        store.contact(directId)?.let { existing ->
            val accepted = existing.copy(accepted = true, blocked = false)
            store.putContact(accepted)
            store.save()
            refreshWatch()
            publish()
            return@onNode accepted
        }
        val url = bootstrap.url
            ?: throw DirectException(DirectException.Reason.NO_BOOTSTRAP, "Set the bootstrap first. Use the same address on both phones, such as ws://192.168.1.20:8787, while the signaling server is running.")
        if (!bootstrap.status.value.isOpen) {
            bootstrap.reconnectNow()
            withTimeoutOrNull(CONNECT_WAIT_MS) { bootstrap.status.first { it.isOpen } }
        }
        if (!bootstrap.status.value.isOpen) {
            throw DirectException(DirectException.Reason.BOOTSTRAP_OFFLINE, "This phone is not connected to the bootstrap at $url. Check that the signaling server is running and that both phones use this address.")
        }
        var published: String? = null
        val deadline = clock() + LOOKUP_RETRY_MS
        while (published == null) {
            published = bootstrap.lookup(directId)
            if (published != null || clock() >= deadline || !bootstrap.status.value.isOpen) break
            delay(300)
        }
        published ?: throw DirectException(DirectException.Reason.NOT_FOUND, "No phone on $url is publishing $directId. Open DIRECT on the other phone with this same bootstrap address.")
        val bundle = verifiedBundle(published, directId)
        saveContact(bundle, accepted = true)
    }

    /** Adds a contact from the bundle in their QR code, with no bootstrap involved. */
    suspend fun addContactBundle(serialized: String): ContactRecord = onNode { addBundle(serialized) }

    private fun addBundle(serialized: String): ContactRecord {
        val self = keys ?: throw DirectException(DirectException.Reason.NO_IDENTITY, "Create your identity first.")
        val bundle = try {
            Bundles.parse(serialized)
        } catch (error: Exception) {
            throw DirectException(DirectException.Reason.BAD_BUNDLE, error.message ?: "That identity bundle could not be verified.")
        }
        if (bundle.directId == self.directId) throw DirectException(DirectException.Reason.SELF, "This DIRECT ID belongs to this phone.")
        return saveContact(bundle, accepted = true)
    }

    suspend fun send(peerId: String, body: String): MessageRecord = onNode {
        val contact = store.contact(peerId) ?: throw DirectException(DirectException.Reason.NOT_FOUND, "That contact is not on this phone.")
        if (contact.blocked) throw DirectException(DirectException.Reason.BLOCKED, "This contact is blocked.")
        if (!contact.accepted) throw DirectException(DirectException.Reason.NOT_ACCEPTED, "Accept the message request before replying.")
        val message = try {
            requireEngine().queueText(peerId, body)
        } catch (error: DeliveryRejected) {
            throw DirectException(DirectException.Reason.REJECTED, error.message ?: "Message was not queued.")
        }
        publish()
        wake.trySend(Unit)
        message
    }

    /** Photo, video, GIF, sticker, or voice note. The bytes are sealed and queued on this phone. */
    suspend fun sendMedia(peerId: String, kind: String, mime: String, name: String, bytes: ByteArray, caption: String): MessageRecord = onNode {
        val contact = store.contact(peerId) ?: throw DirectException(DirectException.Reason.NOT_FOUND, "That contact is not on this phone.")
        if (contact.blocked) throw DirectException(DirectException.Reason.BLOCKED, "This contact is blocked.")
        if (!contact.accepted) throw DirectException(DirectException.Reason.NOT_ACCEPTED, "Accept the message request before replying.")
        val message = try {
            requireEngine().queueMedia(peerId, kind, mime, name, bytes, caption)
        } catch (error: DeliveryRejected) {
            throw DirectException(DirectException.Reason.REJECTED, error.message ?: "Attachment was not queued.")
        }
        publish()
        wake.trySend(Unit)
        message
    }

    suspend fun readMedia(messageId: String): ByteArray? = onNode {
        val name = store.message(messageId)?.mediaFile ?: return@onNode null
        val file = mediaDir?.let { File(it, name) } ?: return@onNode null
        if (!file.exists()) null else file.readBytes()
    }

    suspend fun setStatus(text: String) = onNode {
        val profile = store.profile ?: throw DirectException(DirectException.Reason.NO_IDENTITY, "Create your identity first.")
        store.profile = profile.copy(status = text.trim().take(80))
        store.save()
        publish()
    }

    suspend fun setAvatar(jpeg: ByteArray) = onNode {
        val profile = store.profile ?: throw DirectException(DirectException.Reason.NO_IDENTITY, "Create your identity first.")
        if (jpeg.size > MediaNotes.MAX_AVATAR_BYTES || jpeg.size < 3 || jpeg[0] != 0xFF.toByte() || jpeg[1] != 0xD8.toByte()) {
            throw DirectException(DirectException.Reason.REJECTED, "Choose a smaller JPEG photo.")
        }
        store.profile = profile.copy(avatarJpegBase64 = Encoding.base64Url(jpeg))
        store.save()
        publish()
    }

    suspend fun clearAvatar() = onNode {
        val profile = store.profile ?: return@onNode
        store.profile = profile.copy(avatarJpegBase64 = null)
        store.save()
        publish()
    }

    /** Adds the signed bundle inside a QR or share card, and keeps the unsigned status and photo for display. */
    suspend fun addFromShare(text: String): ContactRecord = onNode {
        val card = ProfileCards.parse(text)
        val contact = addBundle(card.bundle)
        val avatar = card.avatarJpeg?.takeIf { it.size in 1..MediaNotes.MAX_AVATAR_BYTES && it.size >= 2 && it[0] == 0xFF.toByte() }
        store.putContact(contact.copy(about = card.status.trim().take(80), avatarJpegBase64 = avatar?.let(Encoding::base64Url) ?: contact.avatarJpegBase64))
        store.save()
        publish()
        store.contact(contact.directId) ?: contact
    }

    suspend fun acceptRequest(peerId: String) = onNode {
        val contact = store.contact(peerId) ?: return@onNode
        store.putContact(contact.copy(accepted = true, blocked = false))
        store.save()
        requireEngine().markRead(peerId)
        refreshWatch()
        publish()
        wake.trySend(Unit)
    }

    /** Declining blocks the sender. Later envelopes from that DIRECT ID are dropped unread. */
    suspend fun declineRequest(peerId: String) = block(peerId)

    suspend fun block(peerId: String) = onNode {
        val contact = store.contact(peerId) ?: return@onNode
        store.putContact(contact.copy(blocked = true))
        store.save()
        engine?.rejectPeer(peerId)
        transport?.close(peerId)
        refreshWatch()
        publish()
    }

    suspend fun removeContact(peerId: String) = onNode {
        engine?.rejectPeer(peerId)
        store.removeContact(peerId)
        store.save()
        transport?.close(peerId)
        refreshWatch()
        publish()
    }

    suspend fun setVerified(peerId: String, verified: Boolean) = onNode {
        val contact = store.contact(peerId) ?: return@onNode
        store.putContact(contact.copy(verified = verified))
        store.save()
        publish()
    }

    /** Opening an accepted conversation sends read receipts, which move the sender to ACKNOWLEDGED. */
    suspend fun openConversation(peerId: String) = onNode {
        if (requireEngine().markRead(peerId) > 0) wake.trySend(Unit)
        publish()
    }

    suspend fun retry(messageId: String) = onNode {
        if (requireEngine().retry(messageId)) wake.trySend(Unit)
        publish()
    }

    suspend fun onForeground() = onNode {
        foreground = true
        if (!bootstrap.status.value.isOpen) bootstrap.reconnectNow()
        publish()
        wake.trySend(Unit)
    }

    suspend fun onBackground() = onNode {
        foreground = false
        store.save()
        publish()
    }

    suspend fun onNetworkAvailable() = onNode {
        networkAvailable = true
        bootstrap.reconnectNow()
        publish()
        wake.trySend(Unit)
    }

    suspend fun onNetworkLost() = onNode {
        networkAvailable = false
        publish()
    }

    /**
     * One bounded delivery pass for a background worker (WorkManager or BGTaskScheduler).
     * Waits for the bootstrap, flushes, then waits for receipts until [budgetMs] runs out.
     * Returns the number of messages still waiting for a receipt.
     */
    suspend fun backgroundFlush(budgetMs: Long): Int {
        start()
        val until = clock() + budgetMs
        withTimeoutOrNull(budgetMs / 3) { bootstrap.status.first { it.isOpen } }
        onNode { engine?.flush(); publish() }
        while (clock() < until && onNode { engine?.awaitingReceipt() == true }) delay(500)
        return onNode {
            store.save()
            engine?.pendingCount() ?: 0
        }
    }

    suspend fun close() {
        onNode {
            loopJob?.cancel()
            watchers.forEach { it.cancel() }
            transport?.closeAll()
            bootstrap.stop()
            store.save()
        }
        scope.cancel()
    }

    private fun activate(identity: IdentityKeys) {
        transport?.closeAll()
        keys = identity
        val profile = store.profile ?: return
        engine = DeliveryEngine(store, { keys?.let { it to profile.deviceId } }, linksProxy, clock, random, ttlMs, mediaDirectory = mediaDir).also { it.recover() }
        transport = transportFactory(bootstrap, identity.directId, scope).also { it.setListener(listener) }
        bootstrap.announce(identity.directId, Bundles.create(identity, profile.name, profile.deviceId).encode())
        refreshWatch()
        wake.trySend(Unit)
    }

    private val linksProxy = object : app.direct.core.delivery.PeerLinks {
        override fun isConnected(peerId: String) = transport?.isConnected(peerId) == true
        override suspend fun connect(peerId: String): Boolean {
            if (!networkAvailable) return false
            if (!bootstrap.status.value.isOpen && transport?.isConnected(peerId) != true) return false
            return transport?.connect(peerId) == true
        }
        override suspend fun send(peerId: String, payload: ByteArray) = transport?.send(peerId, payload) == true
    }

    private val listener = object : PeerListener {
        override fun onPeerConnected(peerId: String) {
            scope.launch { onPresence(peerId, true) }
        }

        override fun onPeerData(peerId: String, payload: ByteArray) {
            scope.launch { incoming(peerId, payload) }
        }

        override fun onPeerClosed(peerId: String) {
            scope.launch { publish() }
        }
    }

    private suspend fun incoming(peerId: String, payload: ByteArray) {
        val self = keys ?: return
        val header = Envelopes.peek(payload) ?: return
        if (header.from != peerId || header.to != self.directId) return
        if (store.contact(peerId) == null) {
            // Unknown sender: they are online right now, so their signed bundle is on the bootstrap.
            // Store the message as a request. If the lookup fails, no ack is sent and the sender retries.
            val published = bootstrap.lookup(peerId) ?: return
            val bundle = try {
                verifiedBundle(published, peerId)
            } catch (_: DirectException) {
                return
            }
            saveContact(bundle, accepted = false)
        }
        requireEngine().receive(peerId, payload)
        publish()
        wake.trySend(Unit)
    }

    private fun onPresence(peerId: String, isOnline: Boolean) {
        if (isOnline) {
            online += peerId
            engine?.peerOnline(peerId)
            wake.trySend(Unit)
        } else {
            online -= peerId
        }
        publish()
    }

    private fun onBootstrapStatus(status: BootstrapStatus) {
        if (status.isOpen) wake.trySend(Unit)
        publish()
    }

    private suspend fun runLoop() {
        while (scope.isActive) {
            engine?.flush()
            publish()
            val next = engine?.nextWakeAt()
            val wait = if (next == null) IDLE_WAKE_MS else (next - clock()).coerceIn(MIN_WAKE_MS, IDLE_WAKE_MS)
            withTimeoutOrNull(wait) { wake.receive() }
        }
    }

    private fun saveContact(bundle: PublicBundle, accepted: Boolean): ContactRecord {
        val existing = store.contact(bundle.directId)
        val contact = ContactRecord(
            directId = bundle.directId,
            name = bundle.name.ifEmpty { bundle.directId },
            bundle = bundle.encode(),
            fingerprint = bundle.fingerprint,
            verified = existing?.verified == true && existing.fingerprint == bundle.fingerprint,
            accepted = accepted || existing?.accepted == true,
            blocked = existing?.blocked == true,
            createdAt = existing?.createdAt ?: clock(),
            about = existing?.about.orEmpty(),
            avatarJpegBase64 = existing?.avatarJpegBase64,
        )
        store.putContact(contact)
        store.save()
        refreshWatch()
        publish()
        return contact
    }

    private fun verifiedBundle(serialized: String, expected: String): PublicBundle {
        val bundle = try {
            Bundles.parse(serialized)
        } catch (error: Exception) {
            throw DirectException(DirectException.Reason.BAD_BUNDLE, error.message ?: "That identity bundle could not be verified.")
        }
        if (bundle.directId != expected) throw DirectException(DirectException.Reason.BAD_BUNDLE, "The bootstrap returned a bundle for a different DIRECT ID.")
        return bundle
    }

    private fun refreshWatch() {
        bootstrap.watch(store.contacts().filter { !it.blocked }.map { it.directId })
    }

    private fun requireEngine(): DeliveryEngine = engine ?: throw DirectException(DirectException.Reason.NO_IDENTITY, "Create your identity first.")

    private fun cleanName(displayName: String): String {
        val name = displayName.trim()
        if (name.isEmpty()) throw DirectException(DirectException.Reason.REJECTED, "Enter a display name.")
        if (name.length > Bundles.MAX_NAME_UTF16) throw DirectException(DirectException.Reason.REJECTED, "Use 32 characters or fewer.")
        return name
    }

    private fun publish() {
        val profile = store.profile
        val identity = keys
        val contacts = store.contacts()
        val byPeer = store.messages().groupBy { it.peerId }.mapValues { (_, list) -> list.sortedBy { it.createdAt } }
        val conversations = contacts.mapNotNull { contact ->
            val thread = byPeer[contact.directId].orEmpty()
            if (contact.blocked && !contact.accepted) return@mapNotNull null
            if (thread.isEmpty() && !contact.accepted) return@mapNotNull null
            Conversation(
                peerId = contact.directId,
                name = contact.name,
                lastBody = thread.lastOrNull()?.let { message -> message.body.ifBlank { MediaNotes.label(message.mediaKind) } },
                lastAt = thread.lastOrNull()?.createdAt ?: contact.createdAt,
                unread = thread.count { it.direction == Direction.INCOMING && !it.read },
                request = !contact.accepted && !contact.blocked,
                blocked = contact.blocked,
            )
        }.sortedByDescending { it.lastAt }
        _state.value = _state.value.copy(
            profile = if (identity != null) profile else null,
            bundle = if (identity != null && profile != null) Bundles.create(identity, profile.name, profile.deviceId).encode() else null,
            bootstrapUrl = store.settings.bootstrapUrl,
            bootstrap = bootstrap.status.value,
            contacts = contacts.sortedBy { it.name.lowercase() },
            conversations = conversations,
            messages = byPeer,
            online = online.toSet(),
            connected = transport?.connectedPeers().orEmpty(),
            pending = engine?.pendingCount() ?: 0,
            foreground = foreground,
            networkAvailable = networkAvailable,
        )
    }

    private suspend fun <T> onNode(block: suspend () -> T): T = withContext(dispatcher) { block() }

    companion object {
        const val CONNECT_WAIT_MS = 3_000L
        const val LOOKUP_RETRY_MS = 2_500L
        const val IDLE_WAKE_MS = 30_000L
        const val MIN_WAKE_MS = 50L
    }
}
