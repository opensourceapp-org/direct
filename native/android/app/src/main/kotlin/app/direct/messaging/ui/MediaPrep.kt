package app.direct.messaging.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.min

data class Prepared(val kind: String, val mime: String, val name: String, val bytes: ByteArray)

object MediaPrep {
    const val MAX_BYTES = 6 * 1024 * 1024

    fun visual(context: Context, uri: Uri): Prepared {
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val name = displayName(context, uri)
        if (mime == "image/gif" || name.endsWith(".gif", ignoreCase = true)) {
            val bytes = read(context, uri)
            if (bytes.size > MAX_BYTES) error("That GIF is over 6 MB. Choose a shorter one.")
            if (bytes.isEmpty()) error("That GIF is empty.")
            return Prepared("gif", "image/gif", name.ifBlank { "animation.gif" }, bytes)
        }
        if (mime.startsWith("video/")) return video(context, uri, mime, name)
        return Prepared("image", "image/jpeg", "photo.jpg", jpeg(context, uri, maxEdge = 1280, maxBytes = MAX_BYTES))
    }

    fun video(context: Context, uri: Uri, mime: String = context.contentResolver.getType(uri) ?: "video/mp4", name: String = displayName(context, uri)): Prepared {
        val bytes = read(context, uri)
        if (bytes.size > MAX_BYTES) error("That video is over 6 MB. Choose a shorter one. DIRECT does not compress video.")
        if (bytes.isEmpty()) error("That video is empty.")
        return Prepared("video", mime.ifBlank { "video/mp4" }, name.ifBlank { "video.mp4" }, bytes)
    }

    fun gif(context: Context, uri: Uri): Prepared = visual(context, uri).let { prepared ->
        if (prepared.kind == "gif") prepared else error("Choose a GIF file.")
    }

    /** A profile photo small enough to store on this phone. */
    fun avatar(context: Context, uri: Uri): ByteArray {
        var edge = 256
        var quality = 80
        while (edge >= 48) {
            val bytes = jpeg(context, uri, maxEdge = edge, maxBytes = Int.MAX_VALUE, quality = quality)
            if (bytes.size in 3..48_000 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) return bytes
            if (quality > 40) quality -= 15 else {
                edge = edge * 3 / 4
                quality = 70
            }
        }
        error("Choose a smaller photo.")
    }

    /** A tiny JPEG for a QR code. Omitted when it would make the code unscannable. */
    fun qrAvatar(jpeg: ByteArray?): ByteArray? {
        if (jpeg == null || jpeg.size < 3) return null
        val source = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
        val scaled = Bitmap.createScaledBitmap(source, 48, 48, true)
        var quality = 50
        var out = compress(scaled, quality)
        while (out.size > 700 && quality > 20) {
            quality -= 10
            out = compress(scaled, quality)
        }
        return out.takeIf { it.size in 3..700 && it[0] == 0xFF.toByte() }
    }

    fun sticker(index: Int): Prepared {
        val bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        when (index % 6) {
            0 -> {
                paint.color = Color.parseColor("#0E6B45")
                canvas.drawCircle(128f, 128f, 110f, paint)
                paint.color = Color.WHITE
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 10f
                paint.strokeCap = Paint.Cap.ROUND
                canvas.drawArc(RectF(78f, 88f, 178f, 188f), 20f, 140f, false, paint)
                paint.style = Paint.Style.FILL
                canvas.drawCircle(98f, 112f, 10f, paint)
                canvas.drawCircle(158f, 112f, 10f, paint)
            }
            1 -> {
                paint.color = Color.parseColor("#C44536")
                canvas.drawCircle(96f, 108f, 48f, paint)
                canvas.drawCircle(160f, 108f, 48f, paint)
                val path = android.graphics.Path().apply {
                    moveTo(58f, 128f)
                    lineTo(128f, 210f)
                    lineTo(198f, 128f)
                }
                canvas.drawPath(path, paint)
            }
            2 -> {
                paint.color = Color.parseColor("#E2A322")
                val path = android.graphics.Path().apply {
                    moveTo(128f, 28f)
                    lineTo(156f, 100f)
                    lineTo(232f, 104f)
                    lineTo(172f, 154f)
                    lineTo(196f, 228f)
                    lineTo(128f, 186f)
                    lineTo(60f, 228f)
                    lineTo(84f, 154f)
                    lineTo(24f, 104f)
                    lineTo(100f, 100f)
                    close()
                }
                canvas.drawPath(path, paint)
            }
            3 -> {
                paint.color = Color.parseColor("#2F6F8F")
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 16f
                paint.strokeCap = Paint.Cap.ROUND
                canvas.drawArc(RectF(40f, 70f, 140f, 170f), 200f, 220f, false, paint)
                canvas.drawArc(RectF(116f, 70f, 216f, 170f), 120f, 220f, false, paint)
            }
            4 -> {
                paint.color = Color.parseColor("#1A1916")
                canvas.drawCircle(128f, 128f, 110f, paint)
                paint.color = Color.parseColor("#F3F1EC")
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 14f
                paint.strokeCap = Paint.Cap.ROUND
                canvas.drawLine(78f, 132f, 114f, 168f, paint)
                canvas.drawLine(114f, 168f, 184f, 92f, paint)
            }
            else -> {
                paint.color = Color.parseColor("#F4C95D")
                canvas.drawCircle(128f, 128f, 56f, paint)
                paint.strokeWidth = 10f
                paint.strokeCap = Paint.Cap.ROUND
                for (i in 0 until 8) {
                    canvas.save()
                    canvas.rotate(i * 45f, 128f, 128f)
                    canvas.drawLine(128f, 36f, 128f, 58f, paint)
                    canvas.restore()
                }
            }
        }
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return Prepared("sticker", "image/png", "sticker.png", stream.toByteArray())
    }

    private fun jpeg(context: Context, uri: Uri, maxEdge: Int, maxBytes: Int, quality: Int = 85): ByteArray {
        val source = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
            ?: error("That photo could not be read.")
        val longest = max(source.width, source.height).coerceAtLeast(1)
        val bitmap = if (longest <= maxEdge) source else {
            val scale = maxEdge.toFloat() / longest
            Bitmap.createScaledBitmap(source, max(1, (source.width * scale).toInt()), max(1, (source.height * scale).toInt()), true)
        }
        var q = quality
        var bytes = compress(bitmap, q)
        while (bytes.size > maxBytes && q > 30) {
            q -= 10
            bytes = compress(bitmap, q)
        }
        if (bytes.size > maxBytes) error("That photo is still over 6 MB after compression.")
        return bytes
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        return stream.toByteArray()
    }

    private fun read(context: Context, uri: Uri): ByteArray =
        context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: error("That file could not be read.")

    private fun displayName(context: Context, uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0) ?: ""
        }
        return ""
    }
}

class VoiceCapture(private val context: Context) {
    private var recorder: MediaRecorder? = null
    private var file: File? = null

    fun start() {
        cancel()
        val out = File(context.cacheDir, "voice-${System.currentTimeMillis()}.m4a")
        @Suppress("DEPRECATION")
        val next = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        next.setAudioSource(MediaRecorder.AudioSource.MIC)
        next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        next.setOutputFile(out.absolutePath)
        next.prepare()
        next.start()
        recorder = next
        file = out
    }

    fun stop(): ByteArray {
        val recorded = file
        try {
            recorder?.stop()
        } catch (_: RuntimeException) {
            recorded?.delete()
            error("That recording is empty.")
        } finally {
            recorder?.release()
            recorder = null
            file = null
        }
        val bytes = recorded?.readBytes() ?: byteArrayOf()
        recorded?.delete()
        if (bytes.isEmpty()) error("That recording is empty.")
        if (bytes.size > MediaPrep.MAX_BYTES) error("That voice message is over 6 MB.")
        return bytes
    }

    fun cancel() {
        try {
            recorder?.stop()
        } catch (_: RuntimeException) {
            // A recorder that never captured a frame throws on stop.
        }
        recorder?.release()
        recorder = null
        file?.delete()
        file = null
    }
}

fun openAttachment(context: Context, bytes: ByteArray, mime: String, id: String, kind: String?) {
    val extension = when {
        mime.contains("mp4") || kind == "video" -> "mp4"
        mime.contains("gif") -> "gif"
        kind == "audio" || mime.contains("audio") || mime.contains("mp4") && kind == "audio" -> "m4a"
        mime.contains("png") -> "png"
        else -> "jpg"
    }
    val safe = if (kind == "audio") "m4a" else extension
    val file = File(context.cacheDir, "$id.$safe")
    file.writeBytes(bytes)
    val uri = FileProvider.getUriForFile(context, "app.direct.messaging.files", file)
    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, "Open"))
}
