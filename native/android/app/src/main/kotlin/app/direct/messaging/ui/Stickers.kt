package app.direct.messaging.ui

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader

/** Original sticker pack shared with the iPhone tray. Index order matches iOS. */
internal object Stickers {
    const val COUNT = 16

    fun bitmap(index: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { isDither = true }
        when (index % COUNT) {
            0 -> smile(canvas, paint)
            1 -> laugh(canvas, paint)
            2 -> love(canvas, paint)
            3 -> wink(canvas, paint)
            4 -> wow(canvas, paint)
            5 -> sad(canvas, paint)
            6 -> angry(canvas, paint)
            7 -> cool(canvas, paint)
            8 -> kiss(canvas, paint)
            9 -> think(canvas, paint)
            10 -> heart(canvas, paint)
            11 -> flame(canvas, paint)
            12 -> thumb(canvas, paint)
            13 -> star(canvas, paint)
            14 -> party(canvas, paint)
            else -> sparkles(canvas, paint)
        }
        return bitmap
    }

    private fun smile(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFE08A.toInt(), 0xFFF5A623.toInt())
        eyes(canvas, paint, 118f)
        blush(canvas, paint)
        mouth(canvas, paint, 156f, 46f, 150f)
    }

    private fun laugh(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFF1A8.toInt(), 0xFFFFC247.toInt())
        joy(canvas, paint, 112f)
        blush(canvas, paint)
        openMouth(canvas, paint, 158f, 34f, true)
    }

    private fun love(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFC2D4.toInt(), 0xFFFF6B93.toInt())
        heartShape(canvas, paint, 92f, 118f, 16f, 0xFFE11D48.toInt(), 0xFFFF8FAB.toInt())
        heartShape(canvas, paint, 164f, 118f, 16f, 0xFFE11D48.toInt(), 0xFFFF8FAB.toInt())
        blush(canvas, paint)
        mouth(canvas, paint, 158f, 40f, 140f)
    }

    private fun wink(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFE08A.toInt(), 0xFFF0B429.toInt())
        eye(canvas, paint, 96f, 120f, 11f, false)
        winkEye(canvas, paint, 162f, 122f, 16f)
        blush(canvas, paint)
        mouth(canvas, paint, 156f, 42f, 150f)
    }

    private fun wow(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFB8F2FF.toInt(), 0xFF3DB7E0.toInt())
        eye(canvas, paint, 96f, 112f, 14f, false)
        eye(canvas, paint, 160f, 112f, 14f, false)
        paint.style = Paint.Style.FILL
        paint.color = 0xFF1E3A4C.toInt()
        canvas.drawCircle(128f, 168f, 18f, paint)
        paint.color = 0xFFFF8A80.toInt()
        canvas.drawCircle(128f, 174f, 9f, paint)
    }

    private fun sad(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFD7E6FF.toInt(), 0xFF6C8CFF.toInt())
        eye(canvas, paint, 96f, 124f, 10f, false)
        eye(canvas, paint, 160f, 124f, 10f, false)
        brow(canvas, paint, 96f, 100f, true)
        brow(canvas, paint, 160f, 100f, false)
        paint.color = 0xFF243B73.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 7f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawArc(RectF(88f, 168f, 168f, 214f), 200f, 140f, false, paint)
        paint.style = Paint.Style.FILL
    }

    private fun angry(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFB4A2.toInt(), 0xFFE24B3B.toInt())
        brow(canvas, paint, 96f, 104f, false)
        brow(canvas, paint, 160f, 104f, true)
        eye(canvas, paint, 96f, 128f, 9f, false)
        eye(canvas, paint, 160f, 128f, 9f, false)
        paint.color = 0xFF6B1D16.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 8f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawLine(96f, 176f, 160f, 176f, paint)
        paint.style = Paint.Style.FILL
    }

    private fun cool(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFB8F7D4.toInt(), 0xFF1FA971.toInt())
        paint.color = 0xFF14231C.toInt()
        val frame = Path().apply {
            addRoundRect(RectF(58f, 108f, 122f, 142f), 12f, 12f, Path.Direction.CW)
            addRoundRect(RectF(134f, 108f, 198f, 142f), 12f, 12f, Path.Direction.CW)
        }
        canvas.drawPath(frame, paint)
        paint.strokeWidth = 8f
        paint.style = Paint.Style.STROKE
        canvas.drawLine(122f, 124f, 134f, 124f, paint)
        paint.style = Paint.Style.FILL
        paint.color = Color.argb(90, 255, 255, 255)
        canvas.drawRoundRect(RectF(68f, 114f, 96f, 124f), 4f, 4f, paint)
        canvas.drawRoundRect(RectF(144f, 114f, 172f, 124f), 4f, 4f, paint)
        mouth(canvas, paint, 162f, 36f, 140f)
    }

    private fun kiss(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFD0E0.toInt(), 0xFFFF6FA0.toInt())
        eye(canvas, paint, 96f, 118f, 10f, false)
        eye(canvas, paint, 160f, 118f, 10f, false)
        blush(canvas, paint)
        paint.shader = RadialGradient(128f, 168f, 28f, 0xFFFF5C8A.toInt(), 0xFFC2185B.toInt(), Shader.TileMode.CLAMP)
        canvas.drawCircle(128f, 170f, 22f, paint)
        paint.shader = null
        paint.color = Color.argb(80, 255, 255, 255)
        canvas.drawCircle(120f, 162f, 6f, paint)
    }

    private fun think(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFE6DCFF.toInt(), 0xFF8B6CFF.toInt())
        eye(canvas, paint, 108f, 120f, 10f, false)
        eye(canvas, paint, 156f, 114f, 10f, false)
        brow(canvas, paint, 108f, 98f, true)
        paint.color = 0xFF3B2A6B.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 7f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawArc(RectF(108f, 150f, 168f, 188f), 10f, 80f, false, paint)
        paint.style = Paint.Style.FILL
        paint.color = 0xFFFFE0B2.toInt()
        canvas.drawCircle(176f, 186f, 16f, paint)
        canvas.drawRoundRect(RectF(168f, 176f, 214f, 206f), 14f, 14f, paint)
    }

    private fun heart(canvas: Canvas, paint: Paint) {
        shadow(canvas, paint, 128f, 168f, 70f)
        heartShape(canvas, paint, 128f, 132f, 62f, 0xFFFF4D6D.toInt(), 0xFFC9184A.toInt())
        paint.shader = null
        paint.color = Color.argb(110, 255, 255, 255)
        canvas.drawCircle(100f, 112f, 14f, paint)
    }

    private fun flame(canvas: Canvas, paint: Paint) {
        shadow(canvas, paint, 128f, 190f, 60f)
        val outer = Path().apply {
            moveTo(128f, 28f)
            cubicTo(168f, 78f, 214f, 110f, 196f, 168f)
            cubicTo(184f, 214f, 150f, 236f, 128f, 236f)
            cubicTo(106f, 236f, 72f, 214f, 60f, 168f)
            cubicTo(42f, 110f, 88f, 78f, 128f, 28f)
            close()
        }
        paint.shader = RadialGradient(128f, 180f, 120f, 0xFFFFF3B0.toInt(), 0xFFFF6A00.toInt(), Shader.TileMode.CLAMP)
        canvas.drawPath(outer, paint)
        val inner = Path().apply {
            moveTo(128f, 96f)
            cubicTo(150f, 128f, 168f, 150f, 156f, 186f)
            cubicTo(148f, 210f, 136f, 220f, 128f, 220f)
            cubicTo(118f, 220f, 104f, 206f, 100f, 182f)
            cubicTo(92f, 148f, 108f, 126f, 128f, 96f)
            close()
        }
        paint.shader = RadialGradient(128f, 190f, 70f, 0xFFFFFFFF.toInt(), 0xFFFFC107.toInt(), Shader.TileMode.CLAMP)
        canvas.drawPath(inner, paint)
        paint.shader = null
    }

    private fun thumb(canvas: Canvas, paint: Paint) {
        shadow(canvas, paint, 128f, 176f, 70f)
        paint.shader = RadialGradient(120f, 140f, 110f, 0xFFFFE0B8.toInt(), 0xFFE8A15A.toInt(), Shader.TileMode.CLAMP)
        canvas.drawRoundRect(RectF(78f, 108f, 188f, 220f), 40f, 40f, paint)
        canvas.drawRoundRect(RectF(48f, 78f, 118f, 168f), 36f, 36f, paint)
        paint.shader = null
        paint.color = Color.argb(70, 255, 255, 255)
        canvas.drawRoundRect(RectF(96f, 124f, 150f, 150f), 16f, 16f, paint)
    }

    private fun star(canvas: Canvas, paint: Paint) {
        shadow(canvas, paint, 128f, 150f, 80f)
        paint.shader = RadialGradient(128f, 100f, 140f, 0xFFFFF4C2.toInt(), 0xFFFFB703.toInt(), Shader.TileMode.CLAMP)
        canvas.drawPath(starPath(128f, 128f, 100f, 44f), paint)
        paint.shader = null
        eye(canvas, paint, 104f, 124f, 8f, false)
        eye(canvas, paint, 152f, 124f, 8f, false)
        mouth(canvas, paint, 150f, 28f, 140f)
    }

    private fun party(canvas: Canvas, paint: Paint) {
        head(canvas, paint, 0xFFFFE08A.toInt(), 0xFFF5A623.toInt())
        paint.color = 0xFF7C4DFF.toInt()
        val hat = Path().apply {
            moveTo(128f, 28f)
            lineTo(86f, 118f)
            lineTo(170f, 118f)
            close()
        }
        canvas.drawPath(hat, paint)
        paint.color = 0xFFFFD60A.toInt()
        canvas.drawCircle(128f, 28f, 12f, paint)
        paint.color = 0xFFFF4D6D.toInt()
        canvas.drawCircle(108f, 78f, 6f, paint)
        paint.color = 0xFF3DDC97.toInt()
        canvas.drawCircle(146f, 70f, 5f, paint)
        joy(canvas, paint, 132f)
        openMouth(canvas, paint, 168f, 26f, false)
        paint.color = 0xFF3B82F6.toInt()
        canvas.drawCircle(40f, 64f, 7f, paint)
        paint.color = 0xFFFF4D6D.toInt()
        canvas.drawCircle(214f, 80f, 6f, paint)
        paint.color = 0xFF3DDC97.toInt()
        canvas.drawCircle(206f, 168f, 5f, paint)
    }

    private fun sparkles(canvas: Canvas, paint: Paint) {
        spark(canvas, paint, 128f, 118f, 78f, 0xFFFFD60A.toInt())
        spark(canvas, paint, 58f, 70f, 28f, 0xFF7C4DFF.toInt())
        spark(canvas, paint, 196f, 64f, 24f, 0xFF3B82F6.toInt())
        spark(canvas, paint, 188f, 176f, 22f, 0xFFFF4D6D.toInt())
        spark(canvas, paint, 64f, 176f, 18f, 0xFF3DDC97.toInt())
    }

    private fun head(canvas: Canvas, paint: Paint, top: Int, bottom: Int) {
        shadow(canvas, paint, 128f, 150f, 90f)
        paint.shader = RadialGradient(118f, 96f, 150f, top, bottom, Shader.TileMode.CLAMP)
        canvas.drawCircle(128f, 136f, 96f, paint)
        paint.shader = null
        paint.color = Color.argb(80, 255, 255, 255)
        canvas.drawOval(RectF(78f, 62f, 150f, 108f), paint)
    }

    private fun shadow(canvas: Canvas, paint: Paint, cx: Float, cy: Float, r: Float) {
        paint.shader = null
        paint.style = Paint.Style.FILL
        paint.color = Color.argb(40, 30, 20, 10)
        paint.maskFilter = BlurMaskFilter(16f, BlurMaskFilter.Blur.NORMAL)
        canvas.drawOval(RectF(cx - r, cy + 8f, cx + r, cy + 36f), paint)
        paint.maskFilter = null
    }

    private fun eyes(canvas: Canvas, paint: Paint, y: Float) {
        eye(canvas, paint, 96f, y, 11f, false)
        eye(canvas, paint, 160f, y, 11f, false)
    }

    private fun eye(canvas: Canvas, paint: Paint, x: Float, y: Float, r: Float, wink: Boolean) {
        paint.style = Paint.Style.FILL
        paint.color = 0xFF2C241C.toInt()
        if (wink) return
        canvas.drawCircle(x, y, r, paint)
        paint.color = Color.WHITE
        canvas.drawCircle(x - r * 0.28f, y - r * 0.32f, r * 0.32f, paint)
    }

    private fun winkEye(canvas: Canvas, paint: Paint, x: Float, y: Float, r: Float) {
        paint.color = 0xFF2C241C.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 7f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawArc(RectF(x - r, y - r * 0.15f, x + r, y + r), 200f, 140f, false, paint)
        paint.style = Paint.Style.FILL
    }

    private fun joy(canvas: Canvas, paint: Paint, y: Float) {
        paint.color = 0xFF2C241C.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 7f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawArc(RectF(78f, y - 8f, 114f, y + 22f), 200f, 140f, false, paint)
        canvas.drawArc(RectF(142f, y - 8f, 178f, y + 22f), 200f, 140f, false, paint)
        paint.style = Paint.Style.FILL
    }

    private fun brow(canvas: Canvas, paint: Paint, x: Float, y: Float, raised: Boolean) {
        paint.color = 0xFF2C241C.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 7f
        paint.strokeCap = Paint.Cap.ROUND
        val tilt = if (raised) -10f else 10f
        canvas.drawLine(x - 16f, y + tilt, x + 16f, y - tilt, paint)
        paint.style = Paint.Style.FILL
    }

    private fun blush(canvas: Canvas, paint: Paint) {
        paint.color = Color.argb(80, 255, 90, 110)
        canvas.drawCircle(74f, 150f, 14f, paint)
        canvas.drawCircle(182f, 150f, 14f, paint)
    }

    private fun mouth(canvas: Canvas, paint: Paint, y: Float, half: Float, sweep: Float) {
        paint.color = 0xFF5A3418.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 8f
        paint.strokeCap = Paint.Cap.ROUND
        canvas.drawArc(RectF(128f - half, y - half * 0.35f, 128f + half, y + half), 15f, sweep, false, paint)
        paint.style = Paint.Style.FILL
    }

    private fun openMouth(canvas: Canvas, paint: Paint, y: Float, rx: Float, tongue: Boolean) {
        paint.color = 0xFF3B2414.toInt()
        canvas.drawRoundRect(RectF(128f - rx, y - 16f, 128f + rx, y + 22f), 16f, 16f, paint)
        paint.color = Color.WHITE
        canvas.drawRoundRect(RectF(128f - rx + 6f, y - 12f, 128f + rx - 6f, y - 1f), 6f, 6f, paint)
        if (tongue) {
            paint.color = 0xFFFF6B81.toInt()
            canvas.drawOval(RectF(116f, y + 2f, 140f, y + 18f), paint)
        }
    }

    private fun heartShape(canvas: Canvas, paint: Paint, cx: Float, cy: Float, s: Float, top: Int, bottom: Int) {
        val path = Path().apply {
            moveTo(cx, cy + s * 0.85f)
            cubicTo(cx - s * 1.15f, cy + s * 0.15f, cx - s * 1.05f, cy - s * 0.95f, cx, cy - s * 0.25f)
            cubicTo(cx + s * 1.05f, cy - s * 0.95f, cx + s * 1.15f, cy + s * 0.15f, cx, cy + s * 0.85f)
            close()
        }
        paint.shader = RadialGradient(cx, cy - s * 0.2f, s * 1.4f, top, bottom, Shader.TileMode.CLAMP)
        canvas.drawPath(path, paint)
        paint.shader = null
    }

    private fun starPath(cx: Float, cy: Float, outer: Float, inner: Float): Path {
        val path = Path()
        for (point in 0 until 10) {
            val radius = if (point % 2 == 0) outer else inner
            val angle = Math.toRadians(-90.0 + point * 36.0)
            val x = cx + (kotlin.math.cos(angle) * radius).toFloat()
            val y = cy + (kotlin.math.sin(angle) * radius).toFloat()
            if (point == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return path
    }

    private fun spark(canvas: Canvas, paint: Paint, cx: Float, cy: Float, r: Float, color: Int) {
        paint.shader = RadialGradient(cx, cy, r, color, Color.TRANSPARENT, Shader.TileMode.CLAMP)
        paint.color = color
        val path = Path().apply {
            moveTo(cx, cy - r)
            lineTo(cx + r * 0.18f, cy - r * 0.18f)
            lineTo(cx + r, cy)
            lineTo(cx + r * 0.18f, cy + r * 0.18f)
            lineTo(cx, cy + r)
            lineTo(cx - r * 0.18f, cy + r * 0.18f)
            lineTo(cx - r, cy)
            lineTo(cx - r * 0.18f, cy - r * 0.18f)
            close()
        }
        canvas.drawPath(path, paint)
        paint.shader = null
        paint.color = Color.argb(160, 255, 255, 255)
        canvas.drawCircle(cx - r * 0.15f, cy - r * 0.2f, r * 0.12f, paint)
    }
}
