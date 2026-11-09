package app.direct.core.node

import app.direct.core.protocol.CallNotes

enum class CallPhase { OUTGOING, INCOMING, CONNECTING, ACTIVE, ENDED }

data class CallSnapshot(
    val id: String,
    val peerId: String,
    val video: Boolean,
    val phase: CallPhase,
    val outgoing: Boolean,
    val muted: Boolean,
    val speaker: Boolean,
    val cameraOn: Boolean,
    val startedAt: Long?,
    val reason: String?,
    val group: Boolean = false,
    val members: List<String> = emptyList(),
)

sealed class CallEvent {
    data class Begin(val video: Boolean, val outgoing: Boolean, val peerId: String) : CallEvent()
    data class Offer(val sdp: String, val peerId: String) : CallEvent()
    data class Answer(val sdp: String, val peerId: String) : CallEvent()
    data class Ice(val candidate: String, val mid: String, val line: Int, val peerId: String) : CallEvent()
    data object End : CallEvent()
}

class CallRejected(message: String) : Exception(message)

/**
 * One live call on this phone. Signaling is sealed and written on the data channel.
 * Media (microphone, camera, and a peer connection per remote) stays in the app.
 * Group calls are a mesh: each pair of members opens their own connection, and the
 * lower DIRECT ID offers. All methods run on DirectNode's single dispatcher.
 */
internal class CallBoard(
    private val clock: () -> Long,
    private val selfId: () -> String?,
    private val send: suspend (String, CallNotes.Note) -> Boolean,
    private val record: (peerId: String, id: String, outgoing: Boolean, label: String, missed: Boolean) -> Unit,
    private val changed: () -> Unit,
    private val signal: (CallEvent) -> Unit,
) {
    var snapshot: CallSnapshot? = null
        private set
    var ringUntil: Long? = null
        private set

    private val pendingOffer = mutableMapOf<String, String>()
    private val pendingIce = mutableMapOf<String, MutableList<CallEvent.Ice>>()
    private val mediaReady = mutableSetOf<String>()
    private val joined = mutableSetOf<String>()
    private var inviter: String? = null
    private var sessionReady = false

    suspend fun place(peerId: String, video: Boolean, id: String, members: List<String> = emptyList()) {
        val current = snapshot
        if (current != null && current.phase != CallPhase.ENDED) throw CallRejected("A call is already on this phone.")
        val group = members.isNotEmpty()
        snapshot = CallSnapshot(
            id = id,
            peerId = peerId,
            video = video,
            phase = CallPhase.OUTGOING,
            outgoing = true,
            muted = false,
            speaker = video,
            cameraOn = video,
            startedAt = null,
            reason = null,
            group = group,
            members = members,
        )
        ringUntil = clock() + RING_MS
        pendingOffer.clear()
        pendingIce.clear()
        mediaReady.clear()
        joined.clear()
        sessionReady = false
        inviter = selfId()
        changed()
        if (!group) {
            if (!send(peerId, CallNotes.Note("invite", id, kind = if (video) "video" else "audio"))) {
                finish("Unreachable")
                throw CallRejected("That phone is not reachable for a call. Messages still wait on this phone.")
            }
            sessionReady = true
            mediaReady += peerId
            signal(CallEvent.Begin(video, true, peerId))
            return
        }
        var any = false
        val invite = CallNotes.Note("invite", id, kind = if (video) "video" else "audio", groupId = peerId, members = members)
        for (member in members) {
            if (send(member, invite)) any = true
        }
        if (!any) {
            finish("Unreachable")
            throw CallRejected("That phone is not reachable for a call. Messages still wait on this phone.")
        }
        sessionReady = true
    }

    suspend fun accept() {
        val live = snapshot ?: return
        if (live.phase != CallPhase.INCOMING) return
        snapshot = live.copy(phase = CallPhase.CONNECTING, speaker = live.video, cameraOn = live.video)
        ringUntil = null
        sessionReady = true
        changed()
        if (live.group) {
            val target = inviter ?: return
            send(target, CallNotes.Note("accept", live.id, groupId = live.peerId))
            joinAndMesh(target, offer = false)
        } else {
            send(live.peerId, CallNotes.Note("accept", live.id))
            mediaReady += live.peerId
            signal(CallEvent.Begin(live.video, false, live.peerId))
            flushPending(live.peerId)
        }
    }

    suspend fun end() {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED) {
            snapshot = null
            changed()
            return
        }
        if (live.phase == CallPhase.INCOMING) {
            val target = if (live.group) inviter else live.peerId
            if (target != null) send(target, CallNotes.Note("reject", live.id, groupId = live.peerId.takeIf { live.group }))
            finish("Declined")
            return
        }
        hangupAll(live)
        finish(if (live.startedAt == null) "Cancelled" else null)
    }

    fun dismiss() {
        if (snapshot?.phase == CallPhase.ENDED) {
            snapshot = null
            changed()
        }
    }

    suspend fun relayOffer(sdp: String, toPeer: String? = null) {
        val live = snapshot ?: return
        if (!live.outgoing && !live.group) {
            if (live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        } else if (live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) {
            return
        }
        val target = toPeer ?: signalingPeer(live) ?: return
        if (live.group && !live.outgoing && target == signalingPeer(live)) {
            // Callee still answers the inviter; mesh offers go to the named peer.
        }
        send(target, CallNotes.Note("offer", live.id, sdp = sdp, groupId = live.peerId.takeIf { live.group }))
    }

    suspend fun relayAnswer(sdp: String, toPeer: String? = null) {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        val target = toPeer ?: signalingPeer(live) ?: return
        send(target, CallNotes.Note("answer", live.id, sdp = sdp, groupId = live.peerId.takeIf { live.group }))
    }

    suspend fun relayIce(candidate: String, mid: String, line: Int, toPeer: String? = null) {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        val target = toPeer ?: signalingPeer(live) ?: return
        send(target, CallNotes.Note("ice", live.id, candidate = candidate, mid = mid, line = line, groupId = live.peerId.takeIf { live.group }))
    }

    fun markLive() {
        val live = snapshot ?: return
        if (live.phase != CallPhase.CONNECTING && live.phase != CallPhase.OUTGOING) return
        snapshot = live.copy(phase = CallPhase.ACTIVE, startedAt = live.startedAt ?: clock())
        ringUntil = null
        changed()
    }

    fun update(muted: Boolean? = null, speaker: Boolean? = null, camera: Boolean? = null) {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED) return
        snapshot = live.copy(
            muted = muted ?: live.muted,
            speaker = speaker ?: live.speaker,
            cameraOn = camera ?: live.cameraOn,
        )
        changed()
    }

    suspend fun tick() {
        val until = ringUntil ?: return
        if (clock() < until) return
        val live = snapshot ?: return
        ringUntil = null
        when (live.phase) {
            CallPhase.OUTGOING -> {
                hangupAll(live)
                finish("No answer")
            }
            CallPhase.INCOMING -> finish(if (live.video) "Missed video call" else "Missed audio call")
            else -> Unit
        }
    }

    suspend fun onRemote(peerId: String, plain: String) {
        val note = CallNotes.parse(plain) ?: return
        when (note.op) {
            "invite" -> incoming(peerId, note)
            "accept" -> {
                val live = snapshot ?: return
                if (live.id != note.id || live.phase != CallPhase.OUTGOING && !(live.group && live.phase == CallPhase.CONNECTING)) return
                if (live.phase == CallPhase.OUTGOING) {
                    snapshot = live.copy(phase = CallPhase.CONNECTING)
                    ringUntil = null
                    changed()
                }
                if (live.group) joinAndMesh(peerId, offer = true) else Unit
            }
            "reject" -> {
                val live = snapshot ?: return
                if (live.id != note.id) return
                if (live.group) dropMember(peerId, "Call declined") else finish("Call declined")
            }
            "busy" -> {
                val live = snapshot ?: return
                if (live.id != note.id) return
                if (live.group) dropMember(peerId, "Busy") else if (live.phase == CallPhase.OUTGOING) finish("Busy")
            }
            "hangup" -> {
                val live = snapshot ?: return
                if (live.id != note.id || live.phase == CallPhase.ENDED) return
                if (live.group) dropMember(peerId, null) else finish(null)
            }
            "member" -> {
                val live = snapshot ?: return
                val other = note.peer ?: return
                if (live.id != note.id || live.phase == CallPhase.ENDED || !live.group) return
                if (other == selfId()) return
                joinAndMesh(other, offer = true)
            }
            "offer" -> {
                val live = snapshot ?: return
                val sdp = note.sdp ?: return
                if (live.id != note.id) return
                if (sessionReady && (live.phase == CallPhase.CONNECTING || live.phase == CallPhase.ACTIVE || (live.group && live.phase == CallPhase.OUTGOING))) {
                    if (peerId !in mediaReady) {
                        mediaReady += peerId
                        signal(CallEvent.Begin(live.video, false, peerId))
                    }
                    signal(CallEvent.Offer(sdp, peerId))
                } else {
                    pendingOffer[peerId] = sdp
                }
            }
            "answer" -> {
                val live = snapshot ?: return
                val sdp = note.sdp ?: return
                if (live.id != note.id) return
                if (live.phase == CallPhase.OUTGOING) {
                    snapshot = live.copy(phase = CallPhase.CONNECTING)
                    ringUntil = null
                    changed()
                }
                signal(CallEvent.Answer(sdp, peerId))
            }
            "ice" -> {
                val live = snapshot ?: return
                val candidate = note.candidate ?: return
                if (live.id != note.id || live.phase == CallPhase.ENDED) return
                val event = CallEvent.Ice(candidate, note.mid ?: "0", note.line ?: 0, peerId)
                if (sessionReady && live.phase != CallPhase.INCOMING && peerId in mediaReady) {
                    signal(event)
                } else {
                    pendingIce.getOrPut(peerId) { mutableListOf() } += event
                }
            }
        }
    }

    private suspend fun incoming(peerId: String, note: CallNotes.Note) {
        val current = snapshot
        if (current != null && current.phase != CallPhase.ENDED) {
            if (current.phase == CallPhase.OUTGOING && current.peerId == peerId) {
                val self = selfId() ?: return
                if (self <= peerId) return
                signal(CallEvent.End)
                reset()
            } else {
                send(peerId, CallNotes.Note("busy", note.id, groupId = note.groupId))
                return
            }
        }
        val video = note.kind == "video"
        val group = note.groupId != null
        val members = if (group) {
            note.members.filter { it != selfId() }.ifEmpty { listOf(peerId) }
        } else {
            emptyList()
        }
        snapshot = CallSnapshot(
            id = note.id,
            peerId = note.groupId ?: peerId,
            video = video,
            phase = CallPhase.INCOMING,
            outgoing = false,
            muted = false,
            speaker = false,
            cameraOn = false,
            startedAt = null,
            reason = null,
            group = group,
            members = members,
        )
        ringUntil = clock() + RING_MS
        pendingOffer.clear()
        pendingIce.clear()
        mediaReady.clear()
        joined.clear()
        sessionReady = false
        inviter = peerId
        changed()
    }

    private suspend fun joinAndMesh(other: String, offer: Boolean) {
        val live = snapshot ?: return
        val self = selfId() ?: return
        if (other == self) return
        if (!joined.add(other)) {
            if (other !in mediaReady) meshPair(other, offer)
            return
        }
        snapshot = live.copy(members = (live.members + other).distinct())
        changed()
        meshPair(other, offer)
        if (offer) announceMember(other)
    }

    private fun meshPair(other: String, weMayOffer: Boolean) {
        val live = snapshot ?: return
        val self = selfId() ?: return
        if (other in mediaReady) {
            flushPending(other)
            return
        }
        mediaReady += other
        val weOffer = weMayOffer && self < other
        signal(CallEvent.Begin(live.video, weOffer, other))
        flushPending(other)
    }

    private suspend fun announceMember(joinedPeer: String) {
        val live = snapshot ?: return
        if (!live.group) return
        val others = joined.filter { it != joinedPeer }
        for (member in others) {
            send(member, CallNotes.Note("member", live.id, peer = joinedPeer, groupId = live.peerId))
            send(joinedPeer, CallNotes.Note("member", live.id, peer = member, groupId = live.peerId))
        }
    }

    private suspend fun dropMember(peerId: String, reason: String?) {
        val live = snapshot ?: return
        joined.remove(peerId)
        mediaReady.remove(peerId)
        pendingOffer.remove(peerId)
        pendingIce.remove(peerId)
        if (joined.isEmpty() && live.outgoing && live.phase == CallPhase.OUTGOING) {
            if (reason != null && live.members.size <= 1) finish(reason)
            return
        }
        if (joined.isEmpty() && live.phase != CallPhase.OUTGOING) finish(reason)
    }

    private suspend fun hangupAll(live: CallSnapshot) {
        val targets = if (live.group) (live.members + joined).distinct() else listOf(live.peerId)
        for (member in targets) {
            send(member, CallNotes.Note("hangup", live.id, groupId = live.peerId.takeIf { live.group }))
        }
    }

    private fun signalingPeer(live: CallSnapshot): String? =
        if (live.group) inviter.takeUnless { it == selfId() } ?: live.members.firstOrNull() else live.peerId

    private fun flushPending(peerId: String) {
        pendingOffer.remove(peerId)?.let { signal(CallEvent.Offer(it, peerId)) }
        val ice = pendingIce.remove(peerId).orEmpty()
        ice.forEach(signal)
    }

    private fun finish(reason: String?) {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED) return
        signal(CallEvent.End)
        val missed = live.phase == CallPhase.INCOMING && reason != "Declined"
        val label = reason ?: durationLabel(live)
        record(live.peerId, live.id, live.outgoing, label, missed)
        snapshot = live.copy(phase = CallPhase.ENDED, reason = label)
        reset()
        changed()
    }

    private fun reset() {
        ringUntil = null
        pendingOffer.clear()
        pendingIce.clear()
        mediaReady.clear()
        joined.clear()
        sessionReady = false
        inviter = null
    }

    private fun durationLabel(live: CallSnapshot): String {
        val kind = when {
            live.group && live.video -> "Group video"
            live.group -> "Group audio"
            live.video -> "Video"
            else -> "Audio"
        }
        val started = live.startedAt ?: return if (live.outgoing) "No answer" else "Missed $kind call"
        val seconds = ((clock() - started) / 1000).coerceAtLeast(0)
        return "$kind call · ${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
    }

    companion object {
        const val RING_MS = 45_000L
    }
}
