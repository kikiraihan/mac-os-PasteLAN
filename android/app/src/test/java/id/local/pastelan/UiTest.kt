package id.local.pastelan

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import id.local.pastelan.ui.HomeScreen
import id.local.pastelan.ui.LoginScreen
import id.local.pastelan.ui.MainModel
import id.local.pastelan.ui.PasteLANTheme
import id.local.pastelan.ui.SettingsScreen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * Tes tampilan & notifikasi tanpa emulator (Robolectric). Screenshot setiap layar disimpan di
 * app/build/screenshots/ supaya bisa dilihat tanpa HP.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w400dp-h860dp-xhdpi")
class UiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val app: Application = ApplicationProvider.getApplicationContext()

    private val now = System.currentTimeMillis()
    private val items = listOf(
        Clip(5, "text", "ssh deploy@10.0.0.5 -p 2222", "", 27, now - 60_000, "MacBook", "mac", true),
        Clip(4, "image", "", "image/png", 245_000, now - 3_600_000, "MacBook", "mac", false),
        Clip(3, "text", "Alamat: Jl. Merdeka No. 10, Gorontalo\nPatokan: depan masjid", "", 60, now - 7_200_000, "Pixel 8", "hp", false),
    )

    private fun shot(name: String) {
        compose.waitForIdle()
        val view = compose.activity.window.decorView.rootView
        val bmp = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bmp))
        val dir = File("build/screenshots").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun screens() {
        val model = MainModel(app)
        Sync.demo(SyncState(items = items, session = "s1", you = "hp", loaded = true, connected = true))
        var screen by mutableStateOf("login")
        compose.setContent {
            PasteLANTheme {
                when (screen) {
                    "login" -> LoginScreen(model, "https://paste.contoh.id/#pair=AbC123")
                    "home" -> HomeScreen(model) { screen = "settings" }
                    else -> SettingsScreen(model) { screen = "home" }
                }
            }
        }
        compose.onNodeWithText("Scan QR dari Mac").assertExists()
        shot("1-masuk")

        screen = "home"
        compose.onNodeWithText("ssh deploy@10.0.0.5 -p 2222").assertExists()
        compose.onNodeWithText("HP ini · ", substring = true).assertExists() // kiriman HP sendiri
        shot("2-riwayat")

        // ketuk item = salin
        compose.onNodeWithTag("clip-5").performClick()
        compose.waitUntil(3_000) { clipboardText() == "ssh deploy@10.0.0.5 -p 2222" }

        compose.onNodeWithText("Pengaturan", useUnmergedTree = true).assertDoesNotExist()
        screen = "settings"
        compose.onNodeWithText("Salin otomatis").assertExists()
        shot("3-pengaturan")
    }

    private fun clipboardText() =
        app.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString()

    @Test fun notificationCopy() = runBlocking {
        shadowOf(app).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS)
        Notifier.channels(app)
        val clip = items[0]
        Notifier.show(app, clip, "s1")
        val nm = app.getSystemService(NotificationManager::class.java)
        val n = shadowOf(nm).getNotification(Notifier.idFor("s1", clip.id))
        assertNotNull(n)
        assertEquals("Dari MacBook", n.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility) // isi tidak tampil di layar kunci
        val action = n.actions.single()
        assertEquals("Salin", action.title)

        // tombol Salin → teks langsung di clipboard, notifikasi hilang
        val sent = shadowOf(action.actionIntent).savedIntent
        ActionReceiver().onReceive(app, Intent(sent))
        assertEquals("ssh deploy@10.0.0.5 -p 2222", clipboardText())
        assertEquals(null, shadowOf(nm).getNotification(Notifier.idFor("s1", clip.id)))
    }
}
