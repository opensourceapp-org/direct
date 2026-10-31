package app.direct.messaging.ui

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.direct.core.delivery.MessageState
import app.direct.core.signaling.BootstrapStatus

object Ink {
    val foreground = Color(0xFF111111)
    val muted = Color(0xFF6B6B6B)
    val border = Color(0xFFE6E6E6)
    val surface = Color(0xFFF7F7F7)
    val background = Color.White
    val success = Color(0xFF1F7A4D)
    val warning = Color(0xFFB26B00)
    val danger = Color(0xFFB3261E)
}

@Composable
fun DirectTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Ink.foreground,
            onPrimary = Color.White,
            background = Ink.background,
            surface = Ink.background,
            onSurface = Ink.foreground,
            error = Ink.danger,
        ),
    ) {
        Surface(color = Ink.background, contentColor = Ink.foreground, content = content)
    }
}

@Composable
fun Title(text: String) = Text(text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.4).sp)

@Composable
fun Label(text: String) = Text(text, fontSize = 14.sp, fontWeight = FontWeight.Medium)

@Composable
fun Muted(text: String, modifier: Modifier = Modifier) = Text(text, color = Ink.muted, fontSize = 14.sp, lineHeight = 20.sp, modifier = modifier)

@Composable
fun Mono(text: String) = Text(text, fontFamily = FontFamily.Monospace, fontSize = 14.sp)

@Composable
fun PrimaryButton(label: String, enabled: Boolean = true, onClick: () -> Unit) = Button(
    onClick = onClick,
    enabled = enabled,
    shape = RoundedCornerShape(8.dp),
    colors = ButtonDefaults.buttonColors(containerColor = Ink.foreground, contentColor = Color.White),
    modifier = Modifier.fillMaxWidth().height(48.dp),
) { Text(label, fontWeight = FontWeight.Medium) }

@Composable
fun SecondaryButton(label: String, enabled: Boolean = true, onClick: () -> Unit) = OutlinedButton(
    onClick = onClick,
    enabled = enabled,
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, Ink.border),
    colors = ButtonDefaults.outlinedButtonColors(contentColor = Ink.foreground),
    contentPadding = PaddingValues(horizontal = 16.dp),
    modifier = Modifier.fillMaxWidth().height(48.dp),
) { Text(label, fontWeight = FontWeight.Medium) }

@Composable
fun Field(value: String, onChange: (String) -> Unit, placeholder: String, singleLine: Boolean = true, minLines: Int = 1) = OutlinedTextField(
    value = value,
    onValueChange = onChange,
    placeholder = { Text(placeholder, color = Ink.muted) },
    singleLine = singleLine,
    minLines = minLines,
    shape = RoundedCornerShape(8.dp),
    textStyle = TextStyle(fontSize = 16.sp),
    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Ink.foreground, unfocusedBorderColor = Ink.border),
    modifier = Modifier.fillMaxWidth(),
)

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
    Text(label, color = Ink.muted, fontSize = 14.sp)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Dot(color)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun Card(content: @Composable () -> Unit) = Surface(
    shape = RoundedCornerShape(8.dp),
    border = BorderStroke(1.dp, Ink.border),
    color = Ink.background,
    modifier = Modifier.fillMaxWidth(),
) { Column { content() } }

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
