package app.direct.messaging.ui

import android.graphics.Bitmap
import android.graphics.ImageFormat
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
        Muted("This profile is too large for a QR code. Use Share, which sends the same card as text.")
    } else {
        Image(bitmap.asImageBitmap(), "Profile QR code", modifier)
    }
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
