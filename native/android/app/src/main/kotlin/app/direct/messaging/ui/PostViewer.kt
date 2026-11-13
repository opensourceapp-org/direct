package app.direct.messaging.ui

import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.view.Surface
import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import android.graphics.BitmapFactory
import app.direct.core.node.DirectNode
import app.direct.core.node.NodeState
import app.direct.core.store.FeedItem
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

internal const val ZOOM_MIN = 1f
internal const val ZOOM_MAX = 5f
internal const val ZOOM_STEP = 1.4f
internal const val ZOOM_DOUBLE = 2.5f

internal data class Zoom(
    val scale: Float = ZOOM_MIN,
    val offsetX: Float = 0f,
    val offsetY: Float = 0f,
)

internal data class VideoFit(val scaleX: Float, val scaleY: Float)

internal fun zoomClamped(scale: Float): Float {
    if (!scale.isFinite() || scale <= 0f) return ZOOM_MIN
    return scale.coerceIn(ZOOM_MIN, ZOOM_MAX)
}

/** Keeps a zoomed photo inside the viewport. At 1x the offset is cleared. */
internal fun zoomPosition(x: Float, y: Float, scale: Float, width: Float, height: Float): Zoom {
    val next = zoomClamped(scale)
    if (next <= ZOOM_MIN + 0.001f) return Zoom()
    if (width <= 0f || height <= 0f) return Zoom(next)
    val maxX = width * (next - 1f) / 2f
    val maxY = height * (next - 1f) / 2f
    return Zoom(next, x.coerceIn(-maxX, maxX), y.coerceIn(-maxY, maxY))
}

internal fun zoomPinch(current: Zoom, panX: Float, panY: Float, zoomChange: Float, width: Float, height: Float): Zoom =
    zoomPosition(current.offsetX + panX, current.offsetY + panY, current.scale * zoomChange, width, height)

internal fun zoomStep(current: Zoom, factor: Float, width: Float, height: Float): Zoom =
    zoomPosition(current.offsetX, current.offsetY, current.scale * factor, width, height)

internal fun zoomToggle(current: Zoom): Zoom =
    if (current.scale > 1.05f) Zoom() else Zoom(ZOOM_DOUBLE)

/** Letterbox a video that is stretched to fill [viewWidth] x [viewHeight]. */
internal fun videoFit(viewWidth: Int, viewHeight: Int, videoWidth: Int, videoHeight: Int): VideoFit {
    if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) return VideoFit(1f, 1f)
    val viewRatio = viewWidth.toFloat() / viewHeight
    val videoRatio = videoWidth.toFloat() / videoHeight
    return if (videoRatio > viewRatio) VideoFit(1f, viewRatio / videoRatio) else VideoFit(videoRatio / viewRatio, 1f)
}

@Composable
internal fun FeedMediaViewer(
    node: DirectNode,
    state: NodeState,
    item: FeedItem,
    canDelete: Boolean,
    onClose: () -> Unit,
    onError: (String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val zoom = remember { mutableStateOf(Zoom()) }
    val viewport = remember { mutableStateOf(Offset.Zero) }
    LaunchedEffect(item.id) { zoom.value = Zoom() }
    var comments by remember(item.id) { mutableStateOf(false) }
    var playing by remember(item.id) { mutableStateOf(true) }
    var player by remember(item.id) { mutableStateOf<MediaPlayer?>(null) }
    var error by remember(item.id) { mutableStateOf<String?>(null) }
    val transform = rememberTransformableState { zoomChange, pan, _ ->
        zoom.value = zoomPinch(zoom.value, pan.x, pan.y, zoomChange, viewport.value.x, viewport.value.y)
    }
    fun apply(next: Zoom) {
        zoom.value = next
    }
    BackHandler {
        if (comments) comments = false else onClose()
    }
    LaunchedEffect(comments, playing, player) {
        val media = player ?: return@LaunchedEffect
        if (item.kind != "video") return@LaunchedEffect
        if (comments) runCatching { media.pause() }
        else if (playing) runCatching { media.start() }
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onSizeChanged { viewport.value = Offset(it.width.toFloat(), it.height.toFloat()) },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = zoom.value.scale
                    scaleY = zoom.value.scale
                    translationX = zoom.value.offsetX
                    translationY = zoom.value.offsetY
                },
            contentAlignment = Alignment.Center,
        ) {
            ViewerMedia(node, item, Modifier.fillMaxSize()) { player = it }
        }
        Box(
            Modifier
                .fillMaxSize()
                .transformable(state = transform)
                .clearAndSetSemantics { }
                .pointerInput(item.id) {
                    detectTapGestures(onDoubleTap = { apply(zoomToggle(zoom.value)) })
                },
        )
        val percent = (zoom.value.scale * 100).toInt().coerceIn(100, 500)
        val canZoomOut = zoom.value.scale > 1.05f
        val canZoomIn = zoom.value.scale < ZOOM_MAX - 0.01f
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                ViewerIcon(Icons.Filled.Close, "Close", onClick = onClose)
                Row {
                    ViewerIcon(Icons.Outlined.ChatBubbleOutline, "Comments") { comments = true }
                    if (canDelete) {
                        ViewerIcon(Icons.Outlined.Delete, "Delete") {
                            scope.launch {
                                try {
                                    node.deleteFeed(item.id)
                                    onError(null)
                                    onClose()
                                } catch (exception: Exception) {
                                    val message = exception.message ?: "That post was not deleted."
                                    error = message
                                    onError(message)
                                }
                            }
                        }
                    }
                }
            }
            Column(Modifier.padding(bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                error?.let {
                    Text(it, color = Color(0xFFFF8A80), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                }
                Row(
                    Modifier.clip(RoundedCornerShape(28.dp)).background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ViewerIcon(Icons.Filled.ZoomOut, "Zoom out", enabled = canZoomOut) {
                        apply(zoomStep(zoom.value, 1f / ZOOM_STEP, viewport.value.x, viewport.value.y))
                    }
                    Text(
                        "$percent%",
                        color = Color.White,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(52.dp),
                    )
                    ViewerIcon(Icons.Filled.ZoomIn, "Zoom in", enabled = canZoomIn) {
                        apply(zoomStep(zoom.value, ZOOM_STEP, viewport.value.x, viewport.value.y))
                    }
                    if (item.kind == "video") {
                        ViewerIcon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play") {
                            val media = player ?: return@ViewerIcon
                            val next = !playing
                            val ok = runCatching { if (next) media.start() else media.pause() }.isSuccess
                            if (ok) playing = next
                        }
                    }
                }
            }
        }
        if (comments) {
            FeedLightbox(
                node, state, item, canDelete,
                onDelete = {
                    scope.launch {
                        try {
                            node.deleteFeed(item.id)
                            onError(null)
                            onClose()
                        } catch (exception: Exception) {
                            val message = exception.message ?: "That post was not deleted."
                            error = message
                            onError(message)
                            comments = false
                        }
                    }
                },
                onClose = { comments = false },
                onOpenMedia = { comments = false },
                onError = onError,
            )
        }
    }
}

@Composable
private fun ViewerIcon(
    image: ImageVector,
    label: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick, enabled = enabled) {
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(Color.Black.copy(alpha = if (enabled) 0.45f else 0.2f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                image,
                label,
                tint = Color.White.copy(alpha = if (enabled) 1f else 0.35f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun ViewerMedia(
    node: DirectNode,
    item: FeedItem,
    modifier: Modifier,
    onPlayer: (MediaPlayer) -> Unit,
) {
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
        ZoomVideo(data, item.id, modifier, onPlayer)
    } else {
        val bitmap = remember(data) { BitmapFactory.decodeByteArray(data, 0, data.size)?.asImageBitmap() }
        if (bitmap != null) {
            Image(bitmap, item.caption.ifBlank { item.name }, modifier, contentScale = ContentScale.Fit)
        } else {
            Box(modifier, contentAlignment = Alignment.Center) {
                Text("This photo could not be opened.", color = Color.White)
            }
        }
    }
}

@Composable
private fun ZoomVideo(
    bytes: ByteArray,
    id: String,
    modifier: Modifier,
    onPlayer: (MediaPlayer) -> Unit,
) {
    val context = LocalContext.current
    val file = remember(id, bytes) {
        File(context.cacheDir, "feed-view-$id.mp4").also { it.writeBytes(bytes) }
    }
    var failed by remember(id) { mutableStateOf(false) }
    var videoWidth by remember(id) { mutableIntStateOf(0) }
    var videoHeight by remember(id) { mutableIntStateOf(0) }
    val surfaceHolder = remember(id) { arrayOfNulls<Surface>(1) }
    val alive = remember(id) { AtomicBoolean(true) }
    val main = remember { Handler(Looper.getMainLooper()) }
    val player = remember(file.absolutePath) {
        runCatching {
            MediaPlayer().apply {
                setDataSource(file.absolutePath)
                setOnVideoSizeChangedListener { _, width, height ->
                    main.post {
                        if (alive.get()) {
                            videoWidth = width
                            videoHeight = height
                        }
                    }
                }
                setOnPreparedListener {
                    isLooping = false
                    start()
                }
                setOnErrorListener { _, _, _ ->
                    main.post { if (alive.get()) failed = true }
                    true
                }
                prepareAsync()
            }
        }.getOrElse {
            failed = true
            null
        }
    }
    DisposableEffect(player) {
        onDispose {
            alive.set(false)
            surfaceHolder[0]?.let { runCatching { it.release() } }
            surfaceHolder[0] = null
            runCatching { player?.release() }
        }
    }
    if (failed || player == null) {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text("This video could not be opened.", color = Color.White)
        }
        return
    }
    SideEffect { onPlayer(player) }
    fun attach(texture: SurfaceTexture) {
        runCatching {
            surfaceHolder[0]?.release()
            val surface = Surface(texture)
            surfaceHolder[0] = surface
            player.setSurface(surface)
        }
    }
    AndroidView(
        factory = { TextureView(it) },
        update = { view ->
            if (view.width > 0 && videoWidth > 0) {
                val fit = videoFit(view.width, view.height, videoWidth, videoHeight)
                view.setTransform(Matrix().apply { setScale(fit.scaleX, fit.scaleY, view.width / 2f, view.height / 2f) })
            }
            view.surfaceTexture?.let { texture ->
                if (view.tag != texture) {
                    view.tag = texture
                    attach(texture)
                }
            }
            if (view.surfaceTextureListener == null) {
                view.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                        view.tag = surface
                        attach(surface)
                    }
                    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
                        val fit = videoFit(width, height, videoWidth, videoHeight)
                        view.setTransform(Matrix().apply { setScale(fit.scaleX, fit.scaleY, width / 2f, height / 2f) })
                    }
                    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                        view.tag = null
                        runCatching { player.setSurface(null) }
                        return true
                    }
                    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
                }
            }
        },
        modifier = modifier,
    )
}
