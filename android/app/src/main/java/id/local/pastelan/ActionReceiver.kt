package id.local.pastelan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Tombol Salin di notifikasi: langsung masuk clipboard tanpa membuka aplikasi. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != COPY) return
        val app = ctx.applicationContext
        val nid = intent.getIntExtra("nid", 0)
        val text = intent.getStringExtra("text")
        if (text != null) { // teks pendek ikut di notifikasi → tidak perlu jaringan
            Clipboard.copyText(app, text)
            Notifier.cancel(app, nid)
            return
        }
        val session = intent.getStringExtra("session").orEmpty()
        val id = intent.getLongExtra("id", 0)
        // null bila receiver dipanggil langsung (mis. tes), bukan lewat sistem.
        val pending: PendingResult? = goAsync()
        scope.launch {
            try {
                val api = Prefs(app).api()
                val clip = find(app, api, session, id) ?: throw ApiException(404, "Kiriman ini sudah tidak ada di riwayat server")
                Clipboard.copy(app, clip, session, api)
                Notifier.cancel(app, nid)
            } catch (e: ApiException) {
                Clipboard.main { Toast.makeText(app, e.message ?: "Gagal menyalin", Toast.LENGTH_LONG).show() }
            } finally {
                pending?.finish()
            }
        }
    }

    companion object {
        const val COPY = "id.local.pastelan.COPY"
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        /** Item dari daftar di memori, atau diambil lagi dari server (proses aplikasi mungkin sudah ditutup Android). */
        suspend fun find(ctx: Context, api: Api, session: String, id: Long): Clip? {
            val s = Sync.state.value
            if (s.session == session) s.items.firstOrNull { it.id == id }?.let { return it }
            val p = api.items("", 0, -1, wait = false)
            return if (p.session == session) p.items.firstOrNull { it.id == id } else null
        }
    }
}
