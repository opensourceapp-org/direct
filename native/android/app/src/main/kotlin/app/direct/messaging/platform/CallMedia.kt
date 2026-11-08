package app.direct.messaging.platform

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import androidx.core.content.ContextCompat
import app.direct.core.node.CallEvent
import app.direct.core.node.CallPhase
import app.direct.core.node.DirectNode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

/**
 * The call's own peer connection. Session descriptions and ICE travel sealed on the data channel,
 * so this connection never talks to the bootstrap. The message channel is left alone.
 */
class CallMedia(
    private val context: Context,
    private val scope: CoroutineScope,
    private val node: DirectNode,
) {
    val egl: EglBase? = EglBase.create()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        .build()

    private val factory: PeerConnectionFactory
    private var audioModule: org.webrtc.JavaAudioDeviceModule? = null
    private var connection: PeerConnection? = null
    private var audioSource: AudioSource? = null
    private var audioTrack: AudioTrack? = null
    private var videoSource: VideoSource? = null
    private var localVideo: VideoTrack? = null
    private var remoteVideo: VideoTrack? = null
    private var capturer: CameraVideoCapturer? = null
    private var texture: SurfaceTextureHelper? = null
    private var localSink: VideoSink? = null
    private var remoteSink: VideoSink? = null
    private var remoteReady = false
    private val pendingIce = mutableListOf<IceCandidate>()
    private var ringing: Ringtone? = null
    private var liveVideo = false
    private var epoch = 0

    init {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions(),
        )
        audioModule = org.webrtc.JavaAudioDeviceModule.builder(context.applicationContext)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()
        val builder = PeerConnectionFactory.builder().setAudioDeviceModule(audioModule)
        egl?.eglBaseContext?.let { context ->
            builder
                .setVideoEncoderFactory(DefaultVideoEncoderFactory(context, true, true))
                .setVideoDecoderFactory(DefaultVideoDecoderFactory(context))
        }
        factory = builder.createPeerConnectionFactory()
        scope.launch {
            node.state.collect { state ->
                val call = state.call
                main.post {
                    if (call?.phase == CallPhase.INCOMING) startRing() else stopRing()
                    if (call != null && call.phase != CallPhase.ENDED) apply(call.muted, call.speaker, call.cameraOn)
                }
            }
        }
    }

    fun onEvent(event: CallEvent) {
        main.post {
            when (event) {
                is CallEvent.Begin -> start(event.video, event.outgoing)
                is CallEvent.Offer -> onOffer(event.sdp)
                is CallEvent.Answer -> onAnswer(event.sdp)
                is CallEvent.Ice -> addIce(event.candidate, event.mid, event.line)
                CallEvent.End -> stop()
            }
        }
    }

    fun setLocalSink(sink: VideoSink?) {
        main.post {
            localVideo?.let { track ->
                localSink?.let { track.removeSink(it) }
                if (sink != null) track.addSink(sink)
            }
            localSink = sink
        }
    }

    fun setRemoteSink(sink: VideoSink?) {
        main.post {
            remoteVideo?.let { track ->
                remoteSink?.let { track.removeSink(it) }
                if (sink != null) track.addSink(sink)
            }
            remoteSink = sink
        }
    }

    fun flipCamera() {
        main.post { capturer?.switchCamera(null) }
    }

    private fun start(video: Boolean, outgoing: Boolean) {
        stop()
        liveVideo = video
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = video
        audioManager.requestAudioFocus(focus)
        try {
            context.startForegroundService(Intent(context, CallService::class.java).putExtra(CallService.EXTRA_VIDEO, video))
        } catch (_: Exception) {
            // The call still runs while the app is open.
        }
        val config = PeerConnection.RTCConfiguration(WebRtcTransport.DEFAULT_ICE).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val token = epoch
        connection = factory.createPeerConnection(config, observer(token)) ?: return
        audioSource = factory.createAudioSource(MediaConstraints())
        audioTrack = factory.createAudioTrack("audio0", audioSource).also {
            it.setEnabled(true)
            connection?.addTrack(it, listOf("direct"))
        }
        if (video && ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            openCamera()
        }
        if (outgoing) {
            val constraints = MediaConstraints().apply {
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (video) "true" else "false"))
            }
            connection?.createOffer(object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription) {
                    connection?.setLocalDescription(object : SdpObserver {
                        override fun onCreateSuccess(description: SessionDescription) = Unit
                        override fun onCreateFailure(error: String?) = Unit
                        override fun onSetSuccess() {
                            scope.launch { node.relayOffer(description.description) }
                        }
                        override fun onSetFailure(error: String?) = Unit
                    }, description)
                }
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() = Unit
                override fun onSetFailure(error: String?) = Unit
            }, constraints)
        }
    }

    private fun openCamera() {
        val enumerator = Camera2Enumerator(context)
        val name = enumerator.deviceNames.firstOrNull { enumerator.isFrontFacing(it) } ?: enumerator.deviceNames.firstOrNull() ?: return
        val camera = enumerator.createCapturer(name, null) as? CameraVideoCapturer ?: return
        val source = factory.createVideoSource(camera.isScreencast)
        val helper = SurfaceTextureHelper.create("direct-camera", egl?.eglBaseContext ?: return)
        camera.initialize(helper, context, source.capturerObserver)
        camera.startCapture(640, 480, 24)
        val track = factory.createVideoTrack("video0", source)
        track.setEnabled(true)
        localSink?.let { track.addSink(it) }
        connection?.addTrack(track, listOf("direct"))
        capturer = camera
        texture = helper
        videoSource = source
        localVideo = track
    }

    private fun onOffer(sdp: String) {
        val connection = connection ?: return
        connection.setRemoteDescription(setObserver(true), SessionDescription(SessionDescription.Type.OFFER, sdp))
    }

    private fun onAnswer(sdp: String) {
        connection?.setRemoteDescription(setObserver(false), SessionDescription(SessionDescription.Type.ANSWER, sdp))
    }

    private fun setObserver(answer: Boolean) = object : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) = Unit
        override fun onCreateFailure(error: String?) = Unit
        override fun onSetSuccess() {
            remoteReady = true
            pendingIce.forEach { connection?.addIceCandidate(it) }
            pendingIce.clear()
            if (!answer) return
            val constraints = MediaConstraints().apply {
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (liveVideo) "true" else "false"))
            }
            connection?.createAnswer(object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription) {
                    connection?.setLocalDescription(object : SdpObserver {
                        override fun onCreateSuccess(description: SessionDescription) = Unit
                        override fun onCreateFailure(error: String?) = Unit
                        override fun onSetSuccess() {
                            scope.launch { node.relayAnswer(description.description) }
                        }
                        override fun onSetFailure(error: String?) = Unit
                    }, description)
                }
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() = Unit
                override fun onSetFailure(error: String?) = Unit
            }, constraints)
        }
        override fun onSetFailure(error: String?) = Unit
    }

    private fun addIce(candidate: String, mid: String, line: Int) {
        val ice = IceCandidate(mid, line, candidate)
        if (remoteReady) connection?.addIceCandidate(ice) else pendingIce += ice
    }

    private fun apply(muted: Boolean, speaker: Boolean, camera: Boolean) {
        audioTrack?.setEnabled(!muted)
        localVideo?.setEnabled(camera)
        audioManager.isSpeakerphoneOn = speaker
    }

    private fun observer(token: Int) = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            if (token != epoch) return
            scope.launch { if (token == epoch) node.relayIce(candidate.sdp, candidate.sdpMid ?: "0", candidate.sdpMLineIndex) }
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            if (token != epoch) return
            if (state == PeerConnection.IceConnectionState.CONNECTED || state == PeerConnection.IceConnectionState.COMPLETED) {
                scope.launch { if (token == epoch) node.markCallLive() }
            }
        }

        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {
            val track = receiver.track() as? VideoTrack ?: return
            main.post {
                remoteVideo = track
                remoteSink?.let { track.addSink(it) }
            }
        }

        override fun onAddStream(stream: MediaStream) {
            val track = stream.videoTracks.firstOrNull() ?: return
            main.post {
                remoteVideo = track
                remoteSink?.let { track.addSink(it) }
            }
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onDataChannel(channel: org.webrtc.DataChannel) = Unit
        override fun onRenegotiationNeeded() = Unit
    }

    private fun startRing() {
        if (ringing?.isPlaying == true) return
        val tone = RingtoneManager.getRingtone(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)) ?: return
        if (Build.VERSION.SDK_INT >= 28) tone.isLooping = true
        tone.play()
        ringing = tone
    }

    private fun stopRing() {
        ringing?.stop()
        ringing = null
    }

    private fun stop() {
        epoch += 1
        stopRing()
        remoteReady = false
        pendingIce.clear()
        capturer?.stopCapture()
        capturer?.dispose()
        capturer = null
        localVideo?.let { track -> localSink?.let { track.removeSink(it) } }
        remoteVideo?.let { track -> remoteSink?.let { track.removeSink(it) } }
        localVideo?.dispose()
        localVideo = null
        remoteVideo = null
        audioTrack?.dispose()
        audioTrack = null
        connection?.close()
        connection?.dispose()
        connection = null
        videoSource?.dispose()
        videoSource = null
        audioSource?.dispose()
        audioSource = null
        texture?.dispose()
        texture = null
        audioManager.abandonAudioFocusRequest(focus)
        audioManager.isSpeakerphoneOn = false
        audioManager.mode = AudioManager.MODE_NORMAL
        context.stopService(Intent(context, CallService::class.java))
    }
}
