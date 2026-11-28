package id.local.pastelan

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Bagikan → PasteLAN (teks / gambar dari aplikasi lain) dan menu pilihan teks "Kirim ke PasteLAN".
 * Tanpa tampilan: langsung dikirim ke server, lalu toast "Terkirim". Link setup yang dibagikan saat belum masuk
 * membuka layar masuk dengan link itu.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val i = intent
        val text = when (i?.action) {
            Intent.ACTION_PROCESS_TEXT -> i.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }.orEmpty()
        val image: Uri? = if (i?.action == Intent.ACTION_SEND && i.type?.startsWith("image/") == true) {
            if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)
        } else null

        val prefs = Prefs(this)
        if (!prefs.loggedIn) {
            startActivity(Intent(this, MainActivity::class.java).apply {
                if (SetupLink.parse(text) != null) putExtra(MainActivity.EXTRA_SETUP_LINK, text.trim())
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            if (SetupLink.parse(text) == null) Toast.makeText(this, "Masuk ke PasteLAN dulu", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        if (text.isBlank() && image == null) {
            Toast.makeText(this, "Tidak ada teks / gambar untuk dikirim", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val app = applicationContext
        lifecycleScope.launch {
            val msg = try {
                val api = prefs.api()
                if (image != null) {
                    val mime = contentResolver.getType(image) ?: i?.type ?: "image/jpeg"
                    val bytes = withContext(Dispatchers.IO) {
                        contentResolver.openInputStream(image)?.use { it.readBytes() }
                    } ?: throw ApiException(0, "Gambar tidak bisa dibaca")
                    if (bytes.size > (30 shl 20)) throw ApiException(413, "Gambar terlalu besar (maks 30 MB)")
                    api.sendImage(bytes, mime, prefs.sendNotify)
                    "Gambar terkirim ke PasteLAN"
                } else {
                    api.sendText(text, prefs.sendNotify)
                    "Terkirim ke PasteLAN"
                }
            } catch (e: ApiException) {
                e.message ?: "Gagal mengirim"
            }
            Toast.makeText(app, msg, Toast.LENGTH_SHORT).show()
            Sync.refresh(app)
            finish()
        }
    }
}
