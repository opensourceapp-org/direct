package app.direct.messaging.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Typography
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.direct.core.delivery.MessageState
import app.direct.core.signaling.BootstrapStatus
import app.direct.messaging.R

/** Plus Jakarta Sans — SIL Open Font License 1.1, https://github.com/tokotype/PlusJakartaSans */
val DirectFont = FontFamily(
    Font(R.font.plus_jakarta_sans_regular, FontWeight.Normal),
    Font(R.font.plus_jakarta_sans_medium, FontWeight.Medium),
    Font(R.font.plus_jakarta_sans_semibold, FontWeight.SemiBold),
    Font(R.font.plus_jakarta_sans_bold, FontWeight.Bold),
)

object Ink {
    val foreground = Color(0xFF111827)
    val muted = Color(0xFF6B7280)
    val border = Color(0xFFE5E7EB)
    val surface = Color.White
    val background = Color(0xFFF3F5F9)
    val accent = Color(0xFF0B57D0)
    val accentSoft = Color(0xFFE8F0FE)
    val incoming = Color(0xFFE8EEF7)
    val success = Color(0xFF1E8E3E)
    val warning = Color(0xFFE37400)
    val danger = Color(0xFFD93025)
}

private fun TextStyle.direct(): TextStyle = copy(fontFamily = DirectFont)

private val DirectTypography: Typography = run {
        val base = Typography()
        Typography(
            displayLarge = base.displayLarge.direct(),
            displayMedium = base.displayMedium.direct(),
            displaySmall = base.displaySmall.direct(),
            headlineLarge = base.headlineLarge.direct(),
            headlineMedium = base.headlineMedium.direct().copy(fontWeight = FontWeight.SemiBold, fontSize = 28.sp, letterSpacing = (-0.5).sp),
            headlineSmall = base.headlineSmall.direct(),
            titleLarge = base.titleLarge.direct().copy(fontWeight = FontWeight.SemiBold),
            titleMedium = base.titleMedium.direct().copy(fontWeight = FontWeight.SemiBold),
            titleSmall = base.titleSmall.direct(),
            bodyLarge = base.bodyLarge.direct().copy(fontSize = 16.sp, lineHeight = 22.sp),
            bodyMedium = base.bodyMedium.direct().copy(fontSize = 14.sp, lineHeight = 20.sp),
            bodySmall = base.bodySmall.direct(),
            labelLarge = base.labelLarge.direct().copy(fontWeight = FontWeight.SemiBold),
            labelMedium = base.labelMedium.direct(),
            labelSmall = base.labelSmall.direct().copy(letterSpacing = 1.1.sp),
        )
    }

@Composable
fun DirectTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Ink.accent,
            onPrimary = Color.White,
            primaryContainer = Ink.accentSoft,
            onPrimaryContainer = Ink.accent,
            secondary = Ink.accent,
            background = Ink.background,
            surface = Ink.surface,
            onSurface = Ink.foreground,
            surfaceVariant = Ink.incoming,
            outline = Ink.border,
            error = Ink.danger,
        ),
        typography = DirectTypography,
    ) {
        Surface(color = Ink.background, contentColor = Ink.foreground, content = content)
    }
}

@Composable
fun Title(text: String) = Text(
    text,
    fontFamily = DirectFont,
    fontSize = 28.sp,
    fontWeight = FontWeight.Bold,
    letterSpacing = (-0.5).sp,
    color = Ink.foreground,
)

@Composable
fun Label(text: String) = Text(text, fontFamily = DirectFont, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Ink.foreground)

@Composable
fun Muted(text: String, modifier: Modifier = Modifier, textAlign: TextAlign? = null) = Text(
    text,
    color = Ink.muted,
    fontFamily = DirectFont,
    fontSize = 14.sp,
    lineHeight = 20.sp,
    textAlign = textAlign,
    modifier = modifier,
)

@Composable
fun Mono(text: String) = Text(text, fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = Ink.muted)

@Composable
fun PrimaryButton(label: String, enabled: Boolean = true, onClick: () -> Unit) = Button(
    onClick = onClick,
    enabled = enabled,
    shape = RoundedCornerShape(16.dp),
    elevation = ButtonDefaults.buttonElevation(defaultElevation = 2.dp, pressedElevation = 0.dp, disabledElevation = 0.dp),
    colors = ButtonDefaults.buttonColors(containerColor = Ink.accent, contentColor = Color.White, disabledContainerColor = Ink.border, disabledContentColor = Ink.muted),
    modifier = Modifier.fillMaxWidth().height(50.dp),
) { Text(label, fontFamily = DirectFont, fontWeight = FontWeight.SemiBold, fontSize = 16.sp) }

@Composable
fun SecondaryButton(label: String, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) = OutlinedButton(
    onClick = onClick,
    enabled = enabled,
    shape = RoundedCornerShape(16.dp),
    border = BorderStroke(1.dp, Ink.border),
    colors = ButtonDefaults.outlinedButtonColors(containerColor = Ink.surface, contentColor = Ink.foreground),
    contentPadding = PaddingValues(horizontal = 16.dp),
    modifier = Modifier.fillMaxWidth().height(50.dp),
) {
    if (icon != null) Icon(icon, null, modifier = Modifier.padding(end = 8.dp).size(18.dp))
    Text(label, fontFamily = DirectFont, fontWeight = FontWeight.SemiBold)
}

@Composable
fun Field(value: String, onChange: (String) -> Unit, placeholder: String, singleLine: Boolean = true, minLines: Int = 1) {
    val focus = LocalFocusManager.current
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        placeholder = { Text(placeholder, color = Ink.muted, fontFamily = DirectFont) },
        singleLine = singleLine,
        minLines = minLines,
        keyboardOptions = KeyboardOptions(imeAction = if (singleLine) ImeAction.Done else ImeAction.Default),
        keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
        shape = RoundedCornerShape(16.dp),
        textStyle = TextStyle(fontSize = 16.sp, fontFamily = DirectFont, color = Ink.foreground),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Ink.accent,
            unfocusedBorderColor = Ink.border,
            focusedContainerColor = Ink.surface,
            unfocusedContainerColor = Ink.surface,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

/**
 * Closes the keyboard on a tap the text field did not use.
 * The down event is not consumed, so a field can still take focus and open the keyboard.
 */
@Composable
fun Modifier.dismissKeyboardOnOutsideTap(): Modifier {
    val focus = LocalFocusManager.current
    return pointerInput(Unit) {
        awaitEachGesture {
            val down = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.changedToDownIgnoreConsumed() }
                ?: return@awaitEachGesture
            val pointerId = down.id
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Final)
                val change = event.changes.firstOrNull { it.id == pointerId } ?: return@awaitEachGesture
                if (change.changedToUp()) {
                    if (!change.isConsumed) focus.clearFocus()
                    return@awaitEachGesture
                }
                if (change.isConsumed || !change.pressed) return@awaitEachGesture
            }
        }
    }
}

@Composable
fun Dot(color: Color) = Box(Modifier.size(8.dp).padding(0.dp)) {
    Surface(shape = CircleShape, color = color, modifier = Modifier.size(8.dp)) {}
}

@Composable
fun StatusRow(label: String, value: String, color: Color = Ink.muted) = Row(
    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
    horizontalArrangement = Arrangement.SpaceBetween,
    verticalAlignment = Alignment.CenterVertically,
) {
    Text(label, color = Ink.muted, fontSize = 14.sp, fontFamily = DirectFont)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Dot(color)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Medium, fontFamily = DirectFont)
    }
}

@Composable
fun Card(content: @Composable () -> Unit) = Surface(
    shape = RoundedCornerShape(20.dp),
    border = BorderStroke(1.dp, Ink.border.copy(alpha = 0.7f)),
    color = Ink.surface,
    shadowElevation = 2.dp,
    tonalElevation = 0.dp,
    modifier = Modifier.fillMaxWidth(),
) { Column { content() } }

@Composable
fun HeroIcon(icon: ImageVector, modifier: Modifier = Modifier, size: Dp = 88.dp) {
    Box(
        modifier
            .size(size)
            .shadow(16.dp, CircleShape, ambientColor = Ink.accent.copy(alpha = 0.28f), spotColor = Ink.accent.copy(alpha = 0.2f))
            .clip(CircleShape)
            .background(Brush.linearGradient(listOf(Ink.accent, Color(0xFF4C8DFF)))),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(size * 0.42f))
    }
}

@Composable
fun BrandMark(size: Dp = 88.dp) = HeroIcon(Icons.Outlined.Lock, size = size)

@Composable
fun EmptyState(icon: ImageVector, body: String, modifier: Modifier = Modifier, title: String? = null) {
    Column(
        modifier.fillMaxWidth().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        HeroIcon(icon, size = 76.dp)
        if (title != null) {
            Text(
                title,
                fontFamily = DirectFont,
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp,
                color = Ink.foreground,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 18.dp),
            )
        }
        Muted(body, Modifier.padding(top = if (title != null) 8.dp else 16.dp), textAlign = TextAlign.Center)
    }
}

fun MessageState.label(): String = when (this) {
    MessageState.QUEUED -> "Queued"
    MessageState.SENDING -> "Sending"
    MessageState.SENT -> "Sent"
    MessageState.ACCEPTED -> "Delivered"
    MessageState.ACKNOWLEDGED -> "Read"
    MessageState.FAILED -> "Failed · tap to retry"
}

fun BootstrapStatus.describe(): Pair<String, Color> = when (phase) {
    BootstrapStatus.Phase.NOT_CONFIGURED -> "Not set" to Ink.warning
    BootstrapStatus.Phase.CONNECTING -> "Connecting" to Ink.warning
    BootstrapStatus.Phase.OPEN -> "Connected" to Ink.success
    BootstrapStatus.Phase.RETRYING -> "Retrying" to Ink.danger
    BootstrapStatus.Phase.STOPPED -> "Stopped" to Ink.muted
}
