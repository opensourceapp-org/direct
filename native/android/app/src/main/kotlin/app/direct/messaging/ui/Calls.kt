package app.direct.messaging.ui

import android.Manifest
import android.content.pm.PackageManager
import android.view.MotionEvent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import app.direct.core.Encoding
import app.direct.core.node.CallPhase
import app.direct.core.node.CallSnapshot
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.messaging.DirectApp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

private val CallInk = Color(0xFF101114)
private val CallGreen = Color(0xFF1E8E3E)
private val CallRed = Color(0xFFD93025)

@Composable
internal fun rememberPlaceCall(node: DirectNode, peerId: String, onError: (String) -> Unit): (Boolean) -> Unit {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val context = LocalContext.current
    val wantVideo = remember { booleanArrayOf(false) }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        val video = wantVideo[0]
        val mic = granted[Manifest.permission.RECORD_AUDIO] != false &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val camera = !video || (
            granted[Manifest.permission.CAMERA] != false &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            )
        if (!mic) {
            onError("Microphone access is needed for a call.")
            return@rememberLauncherForActivityResult
        }
        if (!camera) {
            onError("Camera access is needed for a video call.")
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            try {
                node.placeCall(peerId, video)
            } catch (error: Exception) {
                onError(error.message ?: "The call could not start.")
            }
        }
    }
    return { video: Boolean ->
        wantVideo[0] = video
        val needed = buildList {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.RECORD_AUDIO)
            }
            if (video && ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.CAMERA)
            }
        }
        if (needed.isEmpty()) {
            scope.launch {
                try {
                    node.placeCall(peerId, video)
                } catch (error: Exception) {
                    onError(error.message ?: "The call could not start.")
                }
            }
        } else {
            permissions.launch(needed.toTypedArray())
        }
    }
}

@Composable
fun CallActions(node: DirectNode, peerId: String, onError: (String) -> Unit) {
    val start = rememberPlaceCall(node, peerId, onError)
    Row {
        CallHeaderButton(Icons.Filled.Call, "Audio call") { start(false) }
        CallHeaderButton(Icons.Filled.Videocam, "Video call") { start(true) }
    }
}

@Composable
private fun CallHeaderButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).clip(CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = Ink.accent, modifier = Modifier.size(22.dp))
    }
}

@Composable
fun CallOverlay(node: DirectNode, state: NodeState, call: CallSnapshot) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val context = LocalContext.current
    val media = (context.applicationContext as DirectApp).calls
    val contact = state.contacts.firstOrNull { it.directId == call.peerId }
    val group = state.groups.firstOrNull { it.id == call.peerId }
    val conversation = state.conversations.firstOrNull { it.peerId == call.peerId }
    val name = group?.name ?: conversation?.name ?: contact?.name ?: call.peerId
    val view = LocalView.current
    DisposableEffect(Unit) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    BackHandler { scope.launch { node.endCall() } }
    LaunchedEffect(call.phase, call.reason) {
        if (call.phase == CallPhase.ENDED) {
            delay(1600)
            node.dismissCall()
        }
    }
    val wantVideo = remember { booleanArrayOf(call.video) }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        val mic = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val camera = !wantVideo[0] || ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        scope.launch {
            if (mic && camera) node.acceptCall() else node.endCall()
        }
    }
    val density = LocalDensity.current
    val pipOffset = remember(call.peerId) { mutableStateOf(Offset.Zero) }
    val pipDrag = remember {
        object {
            var lastX = 0f
            var lastY = 0f
            var maxW = 0f
            var maxH = 0f
            var pipW = 0f
            var pipH = 0f
            var padTop = 0f
            var padEnd = 0f
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(CallInk)) {
        pipDrag.maxW = constraints.maxWidth.toFloat()
        pipDrag.maxH = constraints.maxHeight.toFloat()
        pipDrag.pipW = with(density) { 104.dp.toPx() }
        pipDrag.pipH = with(density) { 150.dp.toPx() }
        pipDrag.padTop = with(density) { 24.dp.toPx() }
        pipDrag.padEnd = with(density) { 16.dp.toPx() }
        val egl = media.egl?.eglBaseContext
        if (egl != null && call.video && call.phase != CallPhase.INCOMING && call.phase != CallPhase.ENDED) {
            AndroidView(
                factory = { viewContext ->
                    SurfaceViewRenderer(viewContext).apply {
                        init(egl, null)
                        setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                        setEnableHardwareScaler(true)
                        media.setRemoteSink(this)
                    }
                },
                modifier = Modifier.fillMaxSize(),
                onRelease = {
                    media.setRemoteSink(null)
                    it.release()
                },
            )
            if (call.cameraOn) {
                AndroidView(
                    factory = { viewContext ->
                        SurfaceViewRenderer(viewContext).apply {
                            init(egl, null)
                            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
                            setMirror(true)
                            setZOrderMediaOverlay(true)
                            setEnableHardwareScaler(true)
                            media.setLocalSink(this)
                            setOnTouchListener { view, event ->
                                when (event.actionMasked) {
                                    MotionEvent.ACTION_DOWN -> {
                                        pipDrag.lastX = event.rawX
                                        pipDrag.lastY = event.rawY
                                        view.parent?.requestDisallowInterceptTouchEvent(true)
                                        true
                                    }
                                    MotionEvent.ACTION_MOVE -> {
                                        val next = Offset(
                                            pipOffset.value.x + (event.rawX - pipDrag.lastX),
                                            pipOffset.value.y + (event.rawY - pipDrag.lastY),
                                        )
                                        pipOffset.value = clampPip(
                                            next, pipDrag.maxW, pipDrag.maxH, pipDrag.pipW, pipDrag.pipH, pipDrag.padTop, pipDrag.padEnd,
                                        )
                                        pipDrag.lastX = event.rawX
                                        pipDrag.lastY = event.rawY
                                        true
                                    }
                                    else -> true
                                }
                            }
                        }
                    },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(top = 24.dp, end = 16.dp)
                        .offset { IntOffset(pipOffset.value.x.roundToInt(), pipOffset.value.y.roundToInt()) }
                        .size(width = 104.dp, height = 150.dp)
                        .clip(RoundedCornerShape(16.dp)),
                    onRelease = {
                        media.setLocalSink(null)
                        it.release()
                    },
                )
            }
        }
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 16.dp, start = 16.dp, end = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (!(call.video && call.phase == CallPhase.ACTIVE)) {
                Avatar(name, jpegBytes(contact?.avatarJpegBase64), 96.dp)
            }
            Text(name, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Text(callStatus(call), color = Color.White.copy(alpha = 0.72f), fontSize = 15.sp)
            if (call.group && call.members.isNotEmpty()) {
                val memberNames = call.members.joinToString { id ->
                    state.contacts.firstOrNull { it.directId == id }?.name ?: id.take(12)
                }
                Text(memberNames, color = Color.White.copy(alpha = 0.55f), fontSize = 13.sp)
            }
            when (call.phase) {
                CallPhase.INCOMING -> Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                    RoundCallButton(CallRed, Icons.Filled.CallEnd, "Decline") { scope.launch { node.endCall() } }
                    RoundCallButton(CallGreen, Icons.Filled.Call, "Accept") {
                        wantVideo[0] = call.video
                        val needed = buildList {
                            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.RECORD_AUDIO)
                            if (call.video && ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) add(Manifest.permission.CAMERA)
                        }
                        if (needed.isEmpty()) scope.launch { node.acceptCall() } else permissions.launch(needed.toTypedArray())
                    }
                }
                CallPhase.ENDED -> Unit
                else -> Column(
                    Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                        RoundCallButton(Color.White.copy(alpha = 0.16f), if (call.muted) Icons.Filled.MicOff else Icons.Filled.Mic, if (call.muted) "Unmute" else "Mute") {
                            scope.launch { node.setCallMuted(!call.muted) }
                        }
                        RoundCallButton(Color.White.copy(alpha = 0.16f), if (call.speaker) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, if (call.speaker) "Speaker off" else "Speaker") {
                            scope.launch { node.setCallSpeaker(!call.speaker) }
                        }
                        if (call.video) {
                            RoundCallButton(Color.White.copy(alpha = 0.16f), if (call.cameraOn) Icons.Filled.Videocam else Icons.Filled.VideocamOff, if (call.cameraOn) "Camera off" else "Camera on") {
                                scope.launch { node.setCallCamera(!call.cameraOn) }
                            }
                            RoundCallButton(Color.White.copy(alpha = 0.16f), Icons.Filled.Cameraswitch, "Flip camera") { media.flipCamera() }
                        }
                    }
                    RoundCallButton(CallRed, Icons.Filled.CallEnd, "End") { scope.launch { node.endCall() } }
                }
            }
        }
    }
}

private fun clampPip(offset: Offset, maxW: Float, maxH: Float, pipW: Float, pipH: Float, padTop: Float, padEnd: Float): Offset {
    val left = maxW - pipW - padEnd + offset.x
    val top = padTop + offset.y
    val minLeft = 8f
    val minTop = 8f
    val maxLeft = (maxW - pipW - 8f).coerceAtLeast(minLeft)
    val maxTop = (maxH - pipH - 8f).coerceAtLeast(minTop)
    return Offset(left.coerceIn(minLeft, maxLeft) - (maxW - pipW - padEnd), top.coerceIn(minTop, maxTop) - padTop)
}

@Composable
private fun callStatus(call: CallSnapshot): String {
    var now by remember(call.startedAt) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(call.phase, call.startedAt) {
        while (call.phase == CallPhase.ACTIVE) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    return when (call.phase) {
        CallPhase.OUTGOING -> if (call.video) "Calling video…" else "Calling…"
        CallPhase.INCOMING -> if (call.video) "Incoming video call" else "Incoming audio call"
        CallPhase.CONNECTING -> "Connecting…"
        CallPhase.ACTIVE -> {
            val started = call.startedAt ?: now
            val seconds = ((now - started) / 1000).coerceAtLeast(0)
            "%d:%02d".format(seconds / 60, seconds % 60)
        }
        CallPhase.ENDED -> call.reason ?: "Call ended"
    }
}

@Composable
private fun RoundCallButton(color: Color, icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            Modifier
                .size(62.dp)
                .shadow(10.dp, CircleShape)
                .clip(CircleShape)
                .background(color)
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, label, tint = Color.White, modifier = Modifier.size(26.dp))
        }
    }
}

private fun jpegBytes(encoded: String?): ByteArray? = encoded?.let { runCatching { Encoding.fromBase64Url(it) }.getOrNull() }
