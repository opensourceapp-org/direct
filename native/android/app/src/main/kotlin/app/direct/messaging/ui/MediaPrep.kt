package app.direct.messaging.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

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

    const val STICKER_COUNT = Stickers.COUNT

    fun sticker(index: Int): Prepared {
        val stream = ByteArrayOutputStream()
        Stickers.bitmap(index).compress(Bitmap.CompressFormat.PNG, 100, stream)
        return Prepared("sticker", "image/png", "sticker.png", stream.toByteArray())
    }

    private fun jpeg(context: Context, uri: Uri, maxEdge: Int, maxBytes: Int, quality: Int = 85): ByteArray {
        val source = oriented(read(context, uri))
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

    /** Camera photos store portrait as a landscape bitmap plus an EXIF rotation. Apply that before compressing. */
    private fun oriented(bytes: ByteArray): Bitmap {
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: error("That photo could not be read.")
        val orientation = try {
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            else -> return decoded
        }
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
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
    private var startedAt = 0L
    private val levels = ArrayDeque<Float>()

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
        startedAt = SystemClock.elapsedRealtime()
        levels.clear()
    }

    /** One bar of the live recording waveform, from the microphone peak since the last sample. */
    fun sample() {
        val raw = (recorder?.maxAmplitude ?: 0) / 32767f
        val shaped = sqrt(raw.toDouble()).toFloat().coerceIn(0.08f, 1f)
        levels.addLast(shaped)
        while (levels.size > 32) levels.removeFirst()
    }

    fun waveform(): List<Float> = levels.toList()

    fun elapsedMs(): Long = if (recorder == null) 0L else SystemClock.elapsedRealtime() - startedAt

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

/** Bar heights for a voice note, decoded from the AAC recording. Quiet notes stay a flat row. */
object VoiceWaveform {
    fun peaks(bytes: ByteArray, bars: Int = 28): FloatArray {
        val quiet = FloatArray(bars) { 0.22f }
        val file = File.createTempFile("direct-wave", ".m4a")
        var codec: MediaCodec? = null
        val extractor = MediaExtractor()
        try {
            file.writeBytes(bytes)
            extractor.setDataSource(file.absolutePath)
            var track = -1
            var format: MediaFormat? = null
            for (index in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(index)
                val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    track = index
                    format = candidate
                    break
                }
            }
            if (track < 0 || format == null) return quiet
            extractor.selectTrack(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return quiet
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            val samples = ArrayList<Float>(4_096)
            var channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1
            var floatPcm = false
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var spins = 0
            while (spins < 4_000) {
                spins++
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(8_000)
                    if (inIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inIndex)
                        val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                when (val outIndex = decoder.dequeueOutputBuffer(info, 8_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> if (inputDone) break
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val out = decoder.outputFormat
                        if (out.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                        floatPcm = out.containsKey(MediaFormat.KEY_PCM_ENCODING) && out.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                    }
                    else -> if (outIndex >= 0) {
                        val buffer = decoder.getOutputBuffer(outIndex)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.order(ByteOrder.LITTLE_ENDIAN)
                            var channel = 0
                            if (floatPcm) {
                                while (buffer.remaining() >= 4) {
                                    val sample = abs(buffer.float)
                                    if (channel == 0) samples.add(sample)
                                    channel = (channel + 1) % channels
                                }
                            } else {
                                while (buffer.remaining() >= 2) {
                                    val sample = abs(buffer.short.toInt()) / 32768f
                                    if (channel == 0) samples.add(sample)
                                    channel = (channel + 1) % channels
                                }
                            }
                        }
                        decoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            }
            if (samples.isEmpty()) return quiet
            val peaks = FloatArray(bars)
            val width = samples.size.toFloat() / bars
            for (bar in 0 until bars) {
                val start = (bar * width).toInt()
                val end = ((bar + 1) * width).toInt().coerceAtMost(samples.size)
                var loud = 0f
                for (index in start until end) if (samples[index] > loud) loud = samples[index]
                peaks[bar] = loud
            }
            val loudest = peaks.maxOrNull() ?: 0f
            if (loudest < 0.001f) return quiet
            return FloatArray(bars) { index -> (peaks[index] / loudest).coerceIn(0.12f, 1f) }
        } catch (_: Exception) {
            return quiet
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
            file.delete()
        }
    }
}

/** Plays one voice note. Starting a note pauses whichever note was already playing. */
class VoiceNotePlayer(context: Context, bytes: ByteArray, private val onDone: () -> Unit) {
    private val file = File(context.cacheDir, "voice-play-${bytes.contentHashCode()}-${bytes.size}.m4a")
    private var player: MediaPlayer? = null

    init {
        if (!file.exists() || file.length() != bytes.size.toLong()) file.writeBytes(bytes)
        player = MediaPlayer().apply {
            setDataSource(file.absolutePath)
            setOnCompletionListener {
                seekTo(0)
                android.os.Handler(android.os.Looper.getMainLooper()).post(onDone)
            }
            prepare()
        }
        playing += this
    }

    fun play() {
        pauseOthers(this)
        player?.start()
    }

    fun pause() {
        player?.pause()
    }

    fun isPlaying(): Boolean = player?.isPlaying == true

    fun position(): Int = player?.currentPosition ?: 0

    fun duration(): Int = player?.duration ?: 0

    fun release() {
        playing.remove(this)
        player?.release()
        player = null
        file.delete()
    }

    companion object {
        private val playing = mutableListOf<VoiceNotePlayer>()

        fun pauseOthers(except: VoiceNotePlayer) {
            playing.forEach { if (it !== except) it.pause() }
        }
    }
}

fun voiceClock(ms: Long): String {
    if (ms <= 0L) return "0:00"
    val total = ((ms + 500) / 1000).toInt()
    return "%d:%02d".format(total / 60, total % 60)
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
