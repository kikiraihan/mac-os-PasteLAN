package id.local.pastelan.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Warna sama dengan PWA (server/web/style.css): latar abu Apple, kartu putih, satu aksen biru, mode gelap.
private val Blue = Color(0xFF007AFF)
private val BlueDark = Color(0xFF0A84FF)

@Composable
fun PasteLANTheme(content: @Composable () -> Unit) {
    val scheme = if (isSystemInDarkTheme()) {
        darkColorScheme(
            primary = BlueDark, onPrimary = Color.White,
            primaryContainer = Color(0xFF0A2A4D), onPrimaryContainer = Color(0xFFD6E8FF),
            secondary = BlueDark, secondaryContainer = Color(0xFF0A2A4D), onSecondaryContainer = Color(0xFFD6E8FF),
            background = Color.Black, onBackground = Color(0xFFF5F5F7),
            surface = Color.Black, onSurface = Color(0xFFF5F5F7),
            surfaceContainerLowest = Color(0xFF1C1C1E), surfaceContainerLow = Color(0xFF1C1C1E),
            surfaceContainer = Color(0xFF1C1C1E), surfaceContainerHigh = Color(0xFF2C2C2E),
            surfaceContainerHighest = Color(0xFF2C2C2E), surfaceVariant = Color(0xFF2C2C2E),
            onSurfaceVariant = Color(0xFF98989D), outline = Color(0xFF48484A), outlineVariant = Color(0xFF38383A),
            error = Color(0xFFFF453A),
        )
    } else {
        lightColorScheme(
            primary = Blue, onPrimary = Color.White,
            primaryContainer = Color(0xFFE5F0FF), onPrimaryContainer = Color(0xFF00326B),
            secondary = Blue, secondaryContainer = Color(0xFFE5F0FF), onSecondaryContainer = Color(0xFF00326B),
            background = Color(0xFFF5F5F7), onBackground = Color(0xFF1D1D1F),
            surface = Color(0xFFF5F5F7), onSurface = Color(0xFF1D1D1F),
            surfaceContainerLowest = Color.White, surfaceContainerLow = Color.White,
            surfaceContainer = Color.White, surfaceContainerHigh = Color(0xFFF2F2F7),
            surfaceContainerHighest = Color(0xFFE5E5EA), surfaceVariant = Color(0xFFE5E5EA),
            onSurfaceVariant = Color(0xFF6E6E73), outline = Color(0xFFC7C7CC), outlineVariant = Color(0xFFE5E5EA),
            error = Color(0xFFFF3B30),
        )
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

val Ok = Color(0xFF34C759)

/** "14.05" hari ini, "kemarin 14.05", selain itu "3 Des 14.05". */
fun timeLabel(ms: Long, now: Long = System.currentTimeMillis()): String {
    val id = Locale.forLanguageTag("id")
    val day = SimpleDateFormat("yyyyMMdd", id)
    val hm = SimpleDateFormat("HH.mm", id).format(Date(ms))
    return when (day.format(Date(ms))) {
        day.format(Date(now)) -> hm
        day.format(Date(now - 86_400_000)) -> "kemarin $hm"
        else -> SimpleDateFormat("d MMM", id).format(Date(ms)) + " " + hm
    }
}

fun sizeLabel(bytes: Int): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${bytes / 1024} KB"
    else -> String.format(Locale.ROOT, "%.1f MB", bytes / 1048576.0)
}
