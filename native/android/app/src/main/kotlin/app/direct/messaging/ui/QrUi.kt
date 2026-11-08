package app.direct.messaging.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.core.content.FileProvider
import app.direct.core.store.Profile
import java.io.File
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

fun qrBitmap(text: String, size: Int = 640): Bitmap? = try {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
    Bitmap.createBitmap(size, size, Bitmap.Config.RGB_565).also { bitmap ->
        for (x in 0 until size) {
            for (y in 0 until size) {
                bitmap.setPixel(x, y, if (matrix.get(x, y)) 0xFF1A1916.toInt() else 0xFFFFFFFF.toInt())
            }
        }
    }
} catch (_: Exception) {
    null
}

@Composable
fun QrImage(text: String, modifier: Modifier = Modifier) {
    val bitmap = remember(text) { qrBitmap(text) }
    if (bitmap == null) {
        Muted("This profile is too large for a QR code. Remove the photo and try again.")
    } else {
        Image(bitmap.asImageBitmap(), "Profile QR code", modifier)
    }
}

fun profileShareCaption(name: String, status: String, directId: String, server: String): String {
    val lines = mutableListOf(name)
    val about = status.trim()
    if (about.isNotEmpty()) lines.add(about)
    lines.add("DIRECT ID: $directId")
    val address = server.trim()
    lines.add(if (address.isEmpty()) "Server: not set" else "Server: $address")
    lines.add(
        if (address.isEmpty()) "Set a server under Network before sharing. The other phone needs it to connect."
        else "Scan the QR code in DIRECT. Both phones use this server to connect.",
    )
    return lines.joinToString("\n")
}

/** A picture of the QR code with the name, status, DIRECT ID, and server address written beside it. */
fun profileCardBitmap(name: String, status: String, directId: String, server: String, qrText: String): Bitmap? {
    val qr = qrBitmap(qrText, 620) ?: return null
    val width = 900
    val margin = 64
    val content = width - margin * 2
    val about = status.trim()
    val address = server.trim()
    val serverText = if (address.isEmpty()) "Not set" else address
    val footer = if (address.isEmpty()) {
        "Set a server under Network before sharing. The other phone needs it to connect."
    } else {
        "Scan this code in DIRECT. Both phones use this server to connect."
    }
    val nameLayout = centered(name, 44f, Color.BLACK, Typeface.BOLD, content)
    val statusLayout = if (about.isEmpty()) null else centered(about, 28f, 0xFF595959.toInt(), Typeface.NORMAL, content)
    val labelLayout = centered("DIRECT ID", 18f, 0xFF737373.toInt(), Typeface.BOLD, content)
    val idLayout = centered(directId, 22f, Color.BLACK, Typeface.NORMAL, content, monospace = true)
    val serverLabel = centered("Server", 18f, 0xFF737373.toInt(), Typeface.BOLD, content)
    val serverLayout = centered(serverText, 22f, if (address.isEmpty()) 0xFF737373.toInt() else Color.BLACK, Typeface.NORMAL, content, monospace = true)
    val footerLayout = centered(footer, 22f, 0xFF595959.toInt(), Typeface.NORMAL, content)
    var height = margin + nameLayout.height + 16
    if (statusLayout != null) height += statusLayout.height + 20
    height += labelLayout.height + 8 + idLayout.height + 20 + serverLabel.height + 8 + serverLayout.height + 36 + qr.height + 28 + footerLayout.height + margin
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    var y = margin.toFloat()
    fun paint(layout: StaticLayout) {
        canvas.save()
        canvas.translate(margin.toFloat(), y)
        layout.draw(canvas)
        canvas.restore()
        y += layout.height
    }
    paint(nameLayout)
    y += 16
    if (statusLayout != null) {
        paint(statusLayout)
        y += 20
    }
    paint(labelLayout)
    y += 8
    paint(idLayout)
    y += 20
    paint(serverLabel)
    y += 8
    paint(serverLayout)
    y += 36
    canvas.drawBitmap(qr, (width - qr.width) / 2f, y, null)
    y += qr.height + 28
    paint(footerLayout)
    return bitmap
}

fun shareProfile(context: Context, profile: Profile, card: String, server: String) {
    val caption = profileShareCaption(profile.name, profile.status, profile.directId, server)
    val image = profileCardBitmap(profile.name, profile.status, profile.directId, server, card)
    val send = Intent(Intent.ACTION_SEND)
    if (image == null) {
        send.type = "text/plain"
        send.putExtra(Intent.EXTRA_TEXT, caption)
    } else {
        val file = File(context.cacheDir, "direct-profile.png")
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val uri = FileProvider.getUriForFile(context, "app.direct.messaging.files", file)
        send.type = "image/png"
        send.putExtra(Intent.EXTRA_STREAM, uri)
        send.putExtra(Intent.EXTRA_TEXT, caption)
        send.clipData = ClipData.newRawUri("DIRECT profile", uri)
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    val chooser = Intent.createChooser(send, "Share profile").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(chooser)
}

private fun centered(text: String, size: Float, color: Int, style: Int, width: Int, monospace: Boolean = false): StaticLayout {
    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        textSize = size
        typeface = if (monospace) Typeface.create(Typeface.MONOSPACE, style) else Typeface.create(Typeface.DEFAULT, style)
    }
    return StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
        .setAlignment(Layout.Alignment.ALIGN_CENTER)
        .setIncludePad(false)
        .build()
}

@Composable
fun QrScanner(onCode: (String) -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val seen = remember { AtomicBoolean(false) }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { viewContext ->
                val previewView = PreviewView(viewContext)
                val future = ProcessCameraProvider.getInstance(viewContext)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                    val analysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                    analysis.setAnalyzer(executor) { image ->
                        val text = if (seen.get()) null else decodeQr(image)
                        image.close()
                        if (text != null && seen.compareAndSet(false, true)) {
                            previewView.post { onCode(text) }
                        }
                    }
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycleOwner, androidx.camera.core.CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }, ContextCompat.getMainExecutor(context))
                previewView
            },
            modifier = Modifier.fillMaxSize(),
        )
        Box(Modifier.align(Alignment.BottomCenter).padding(24.dp)) {
            SecondaryButton("Close", onClick = onClose)
        }
    }
}

private fun decodeQr(image: ImageProxy): String? {
    if (image.format != ImageFormat.YUV_420_888) return null
    val plane = image.planes.firstOrNull() ?: return null
    val buffer = plane.buffer
    val rowStride = plane.rowStride
    val pixelStride = plane.pixelStride
    val packed = ByteArray(image.width * image.height)
    val row = ByteArray(rowStride)
    for (y in 0 until image.height) {
        val length = minOf(rowStride, buffer.remaining())
        if (length <= 0) return null
        buffer.get(row, 0, length)
        var x = 0
        var offset = 0
        while (x < image.width && offset < length) {
            packed[y * image.width + x] = row[offset]
            x += 1
            offset += pixelStride
        }
    }
    val source = PlanarYUVLuminanceSource(packed, image.width, image.height, 0, 0, image.width, image.height, false)
    return try {
        MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(source))).text
    } catch (_: Exception) {
        null
    }
}
