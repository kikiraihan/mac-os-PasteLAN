package id.local.pastelan.ui

import android.app.Application
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import id.local.pastelan.ActionReceiver
import id.local.pastelan.Api
import id.local.pastelan.ApiException
import id.local.pastelan.Clip
import id.local.pastelan.Clipboard
import id.local.pastelan.Images
import id.local.pastelan.Login
import id.local.pastelan.Prefs
import id.local.pastelan.ServerUrl
import id.local.pastelan.SetupLink
import id.local.pastelan.Sync
import id.local.pastelan.SyncService
import id.local.pastelan.Updater
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainModel(app: Application) : AndroidViewModel(app) {
    private val ctx get() = getApplication<Application>()
    val prefs = Prefs(app)

    var loggedIn by mutableStateOf(prefs.loggedIn)
        private set
    var busy by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null) // pesan singkat (snackbar)
    var loginError by mutableStateOf<String?>(null)
    var highlight by mutableStateOf(0L) // item yang dibuka dari notifikasi
    var update by mutableStateOf<Updater.Release?>(null)

    val state = Sync.state

    fun defaultName(): String = (Build.MANUFACTURER.replaceFirstChar { it.uppercase() } + " " + Build.MODEL)
        .let { if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else it }.take(60)

    // --- masuk / keluar -------------------------------------------------------------

    fun loginWithLink(link: String, name: String) {
        val parsed = SetupLink.parse(link)
        if (parsed == null) {
            loginError = "Link setup tidak dikenal. Bentuknya https://server/#pair=… (dari halaman admin atau QR di Mac)."
            return
        }
        doLogin(parsed.server, name) { it.claimPair(parsed.code, name) }
    }

    fun loginWithPassword(server: String, password: String, name: String) {
        val base = ServerUrl.normalize(server)
        if (base == null) {
            loginError = "Alamat server tidak valid (wajib HTTPS, mis. paste.contoh.id)."
            return
        }
        if (password.isBlank()) {
            loginError = "Isi password perangkat."
            return
        }
        doLogin(base, name) { it.login(password, name) }
    }

    private fun doLogin(base: String, name: String, call: suspend (Api) -> Login) {
        busy = true
        loginError = null
        viewModelScope.launch {
            try {
                val res = call(Api(base, null))
                Sync.reset(ctx)
                prefs.server = base
                prefs.token = res.token
                prefs.deviceName = res.deviceName.ifBlank { name }
                prefs.seenTime = -1
                loggedIn = true
                start()
            } catch (e: ApiException) {
                loginError = e.message
            } finally {
                busy = false
            }
        }
    }

    fun logout() {
        viewModelScope.launch {
            try {
                prefs.api().logout()
            } catch (_: ApiException) {
                // tetap keluar di HP; perangkat bisa dicabut dari halaman admin
            }
            stop() // lepas koneksi; start() setelah masuk lagi memegangnya ulang
            SyncService.stop(ctx)
            prefs.clearSession()
            Sync.reset(ctx)
            loggedIn = false
        }
    }

    // --- sinkron ----------------------------------------------------------------------

    private var holding = false

    /** Layar terlihat: ikut memegang koneksi (dan nyalakan layanan latar bila diizinkan). */
    fun start() {
        if (!loggedIn) return
        if (!holding) {
            holding = true
            Sync.acquire(ctx)
        }
        SyncService.start(ctx)
    }

    fun stop() {
        if (holding) Sync.release()
        holding = false
    }

    /** Token dicabut di server (Sync menandai loggedOut). */
    fun onLoggedOut() {
        stop()
        loggedIn = false
        loginError = "Perangkat ini sudah dikeluarkan dari server. Masuk lagi dengan link setup baru."
    }

    fun setBackgroundSync(on: Boolean) {
        prefs.backgroundSync = on
        if (on) SyncService.start(ctx) else SyncService.stop(ctx)
    }

    // --- kirim / salin / hapus --------------------------------------------------------

    fun sendText(text: String, done: () -> Unit = {}) {
        if (text.isBlank()) return
        busy = true
        viewModelScope.launch {
            try {
                prefs.api().sendText(text, prefs.sendNotify)
                done()
                Sync.refresh(ctx)
            } catch (e: ApiException) {
                message = e.message
            } finally {
                busy = false
            }
        }
    }

    fun sendImage(uri: Uri) {
        busy = true
        viewModelScope.launch {
            try {
                val (bytes, mime) = withContext(Dispatchers.IO) { readImage(uri) }
                prefs.api().sendImage(bytes, mime, prefs.sendNotify)
                message = "Gambar terkirim"
                Sync.refresh(ctx)
            } catch (e: ApiException) {
                message = e.message
            } finally {
                busy = false
            }
        }
    }

    private fun readImage(uri: Uri): Pair<ByteArray, String> {
        val cr = ctx.contentResolver
        val mime = cr.getType(uri) ?: "image/jpeg"
        val bytes = cr.openInputStream(uri)?.use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
                if (total > MAX_IMAGE) throw ApiException(413, "Gambar terlalu besar (maks 30 MB)")
                out.write(buf, 0, n)
            }
            out.toByteArray()
        } ?: throw ApiException(0, "Gambar tidak bisa dibaca")
        return bytes to mime
    }

    fun copy(clip: Clip) {
        viewModelScope.launch {
            try {
                Clipboard.copy(ctx, clip, state.value.session, prefs.api(), toast = false)
                message = if (clip.isImage) "Gambar disalin" else "Teks disalin"
            } catch (e: ApiException) {
                message = e.message
            }
        }
    }

    /** Dibuka dari notifikasi: salin item itu (seperti PWA #copy=…) dan sorot di daftar. */
    fun copyFromNotification(session: String, id: Long) {
        highlight = id
        viewModelScope.launch {
            try {
                val api = prefs.api()
                val clip = ActionReceiver.find(ctx, api, session, id)
                    ?: throw ApiException(404, "Kiriman ini sudah tidak ada di riwayat server")
                Clipboard.copy(ctx, clip, session, api, toast = false)
                message = if (clip.isImage) "Gambar disalin" else "Teks disalin"
            } catch (e: ApiException) {
                message = e.message
            }
        }
    }

    fun delete(clip: Clip) {
        viewModelScope.launch {
            try {
                prefs.api().delete(clip.id)
                Sync.refresh(ctx)
            } catch (e: ApiException) {
                message = e.message
            }
        }
    }

    fun clearAll() {
        viewModelScope.launch {
            try {
                prefs.api().clear()
                Sync.refresh(ctx)
                message = "Riwayat dihapus di semua perangkat"
            } catch (e: ApiException) {
                message = e.message
            }
        }
    }

    /** File gambar untuk daftar (diunduh sekali, disimpan di cache sampai item hilang dari riwayat). */
    suspend fun imageFile(clip: Clip): File? = try {
        Images.ensure(ctx, prefs.api(), state.value.session, clip)
    } catch (_: ApiException) {
        null
    }

    fun shareUri(clip: Clip): Uri = Images.uri(ctx, Images.file(ctx, state.value.session, clip))

    // --- pembaruan ------------------------------------------------------------------------

    fun checkUpdate(manual: Boolean) {
        viewModelScope.launch {
            try {
                val r = Updater.latest()
                update = r.takeIf { Updater.newer(it.version, Updater.current(ctx)) }
                if (manual && update == null) message = "PasteLAN sudah versi terbaru (${Updater.current(ctx)})"
            } catch (e: ApiException) {
                if (manual) message = e.message
            }
        }
    }

    companion object {
        const val MAX_IMAGE = 30 shl 20
    }
}
