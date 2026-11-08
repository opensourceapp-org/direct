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
)

sealed class CallEvent {
    data class Begin(val video: Boolean, val outgoing: Boolean) : CallEvent()
    data class Offer(val sdp: String) : CallEvent()
    data class Answer(val sdp: String) : CallEvent()
    data class Ice(val candidate: String, val mid: String, val line: Int) : CallEvent()
    data object End : CallEvent()
}

class CallRejected(message: String) : Exception(message)

/**
 * One live call on this phone. Signaling is sealed and written on the data channel.
 * Media (microphone, camera, and the second peer connection) stays in the app.
 * All methods run on DirectNode's single dispatcher.
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

    private var pendingOffer: String? = null
    private val pendingIce = mutableListOf<CallEvent.Ice>()
    private var mediaReady = false

    suspend fun place(peerId: String, video: Boolean, id: String) {
        val current = snapshot
        if (current != null && current.phase != CallPhase.ENDED) throw CallRejected("A call is already on this phone.")
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
        )
        ringUntil = clock() + RING_MS
        pendingOffer = null
        pendingIce.clear()
        mediaReady = true
        changed()
        if (!send(peerId, CallNotes.Note("invite", id, kind = if (video) "video" else "audio"))) {
            finish("Unreachable")
            throw CallRejected("That phone is not reachable for a call. Messages still wait on this phone.")
        }
        signal(CallEvent.Begin(video, true))
    }

    suspend fun accept() {
        val live = snapshot ?: return
        if (live.phase != CallPhase.INCOMING) return
        snapshot = live.copy(phase = CallPhase.CONNECTING, speaker = live.video, cameraOn = live.video)
        ringUntil = null
        mediaReady = true
        changed()
        send(live.peerId, CallNotes.Note("accept", live.id))
        signal(CallEvent.Begin(live.video, false))
        flushPending()
    }

    suspend fun end() {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED) {
            snapshot = null
            changed()
            return
        }
        if (live.phase == CallPhase.INCOMING) {
            send(live.peerId, CallNotes.Note("reject", live.id))
            finish("Declined")
            return
        }
        send(live.peerId, CallNotes.Note("hangup", live.id))
        finish(if (live.startedAt == null) "Cancelled" else null)
    }

    fun dismiss() {
        if (snapshot?.phase == CallPhase.ENDED) {
            snapshot = null
            changed()
        }
    }

    suspend fun relayOffer(sdp: String) {
        val live = snapshot ?: return
        if (!live.outgoing || live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        send(live.peerId, CallNotes.Note("offer", live.id, sdp = sdp))
    }

    suspend fun relayAnswer(sdp: String) {
        val live = snapshot ?: return
        if (live.outgoing || live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        send(live.peerId, CallNotes.Note("answer", live.id, sdp = sdp))
    }

    suspend fun relayIce(candidate: String, mid: String, line: Int) {
        val live = snapshot ?: return
        if (live.phase == CallPhase.ENDED || live.phase == CallPhase.INCOMING) return
        send(live.peerId, CallNotes.Note("ice", live.id, candidate = candidate, mid = mid, line = line))
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
                send(live.peerId, CallNotes.Note("hangup", live.id))
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
                if (live.id != note.id || live.phase != CallPhase.OUTGOING) return
                snapshot = live.copy(phase = CallPhase.CONNECTING)
                ringUntil = null
                changed()
            }
            "reject" -> {
                val live = snapshot ?: return
                if (live.id == note.id) finish("Call declined")
            }
            "busy" -> {
                val live = snapshot ?: return
                if (live.id == note.id && live.phase == CallPhase.OUTGOING) finish("Busy")
            }
            "hangup" -> {
                val live = snapshot ?: return
                if (live.id != note.id || live.phase == CallPhase.ENDED) return
                finish(null)
            }
            "offer" -> {
                val live = snapshot ?: return
                val sdp = note.sdp ?: return
                if (live.id != note.id) return
                if (mediaReady && (live.phase == CallPhase.CONNECTING || live.phase == CallPhase.ACTIVE)) {
                    signal(CallEvent.Offer(sdp))
                } else {
                    pendingOffer = sdp
                }
            }
            "answer" -> {
                val live = snapshot ?: return
                val sdp = note.sdp ?: return
                if (live.id != note.id || !live.outgoing) return
                if (live.phase == CallPhase.OUTGOING) {
                    snapshot = live.copy(phase = CallPhase.CONNECTING)
                    ringUntil = null
                    changed()
                }
                signal(CallEvent.Answer(sdp))
            }
            "ice" -> {
                val live = snapshot ?: return
                val candidate = note.candidate ?: return
                if (live.id != note.id || live.phase == CallPhase.ENDED) return
                val event = CallEvent.Ice(candidate, note.mid ?: "0", note.line ?: 0)
                if (mediaReady && live.phase != CallPhase.INCOMING) signal(event) else pendingIce += event
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
                snapshot = null
                pendingOffer = null
                pendingIce.clear()
                mediaReady = false
                ringUntil = null
            } else {
                send(peerId, CallNotes.Note("busy", note.id))
                return
            }
        }
        val video = note.kind == "video"
        snapshot = CallSnapshot(
            id = note.id,
            peerId = peerId,
            video = video,
            phase = CallPhase.INCOMING,
            outgoing = false,
            muted = false,
            speaker = false,
            cameraOn = false,
            startedAt = null,
            reason = null,
        )
        ringUntil = clock() + RING_MS
        mediaReady = false
        changed()
    }

    private fun flushPending() {
        pendingOffer?.let {
            pendingOffer = null
            signal(CallEvent.Offer(it))
        }
        val ice = pendingIce.toList()
        pendingIce.clear()
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
        ringUntil = null
        pendingOffer = null
        pendingIce.clear()
        mediaReady = false
        changed()
    }

    private fun durationLabel(live: CallSnapshot): String {
        val kind = if (live.video) "Video" else "Audio"
        val started = live.startedAt ?: return if (live.outgoing) "No answer" else "Missed $kind call"
        val seconds = ((clock() - started) / 1000).coerceAtLeast(0)
        return "$kind call · ${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
    }

    companion object {
        const val RING_MS = 45_000L
    }
}
