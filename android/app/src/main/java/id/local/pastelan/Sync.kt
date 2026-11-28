package id.local.pastelan

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class SyncState(
    val items: List<Clip> = emptyList(), // terbaru di atas
    val session: String = "",
    val you: String = "",
    val loaded: Boolean = false,
    val connected: Boolean = false,
    val error: String? = null,
    val loggedOut: Boolean = false, // token dicabut di server → kembali ke layar masuk
)

/** Logika daftar & notifikasi tanpa Android (diuji di ParseTest). */
object ClipList {
    /** Gabungkan jawaban polling ke daftar lama. Session beda (server restart / riwayat dihapus) → daftar baru. */
    fun merge(old: List<Clip>, oldSession: String, p: Poll): List<Clip> {
        val base = if (p.session != oldSession) emptyList() else old
        return (base + p.items).associateBy { it.id }.values.filter { it.id in p.ids }.sortedByDescending { it.id }
    }

    /**
     * Item yang perlu diberi tahu: dari perangkat lain, lebih baru dari [seenTime] (jam server), dan — kalau mode
     * [Prefs.NOTIFY_MARKED] — hanya yang dikirim dengan notifikasi. seenTime < 0 = baru masuk (item lama tidak
     * diberi tahu). Maksimal [max] terbaru supaya sambungan yang lama putus tidak membanjiri notifikasi.
     */
    fun toNotify(p: Poll, seenTime: Long, mode: String, max: Int = 5): List<Clip> {
        if (seenTime < 0) return emptyList()
        return p.items.filter { it.device != p.you && it.time > seenTime && (mode == Prefs.NOTIFY_ALL || it.notify) }
            .sortedBy { it.id }.takeLast(max)
    }

    fun seenTime(p: Poll, seenTime: Long) = maxOf(seenTime, p.items.maxOfOrNull { it.time } ?: 0L, 0L)
}

/**
 * Satu koneksi long-poll per proses, dipakai layar utama (saat terlihat) dan SyncService (latar belakang).
 * Selama ada pemegang ([acquire]), daftar riwayat diperbarui dan kiriman baru dari perangkat lain
 * dijadikan notifikasi (dengan tombol Salin) — kecuali saat aplikasi sedang dibuka.
 */
object Sync {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private val _state = MutableStateFlow(SyncState())
    val state: StateFlow<SyncState> = _state.asStateFlow()

    private var holders = 0
    private var job: Job? = null
    private var rev = -1L
    private var cachedApi: Pair<String, Api>? = null

    /** Layar utama sedang terlihat → tidak perlu notifikasi (daftar langsung diperbarui). */
    @Volatile var visible = false

    fun acquire(ctx: Context) = synchronized(this) {
        holders++
        if (job?.isActive != true) job = scope.launch { loop(ctx.applicationContext) }
    }

    fun release() = synchronized(this) {
        holders = maxOf(0, holders - 1)
        if (holders == 0) {
            job?.cancel()
            job = null
            _state.update { it.copy(connected = false) }
        }
    }

    /** Ambil ulang sekarang (setelah kirim / hapus), tanpa menunggu long-poll berikutnya. */
    fun refresh(ctx: Context) {
        val app = ctx.applicationContext
        scope.launch {
            try {
                val api = api(app) ?: return@launch
                apply(app, api.items(_state.value.session, after(), rev, wait = false))
            } catch (_: ApiException) {
                // loop utama yang menampilkan status koneksi
            }
        }
    }

    /** Keluar / ganti akun: kosongkan semua yang ada di memori & cache gambar. */
    fun reset(ctx: Context) {
        synchronized(this) {
            job?.cancel()
            job = null
            rev = -1
            cachedApi = null
            _state.value = SyncState()
            if (holders > 0) job = scope.launch { loop(ctx.applicationContext) }
        }
        Images.clear(ctx)
    }

    /** Hanya untuk tes tampilan (Robolectric): isi daftar tanpa server. */
    internal fun demo(s: SyncState) {
        _state.value = s
    }

    private fun after() = _state.value.items.maxOfOrNull { it.id } ?: 0L

    private fun api(ctx: Context): Api? {
        val p = Prefs(ctx)
        if (p.server.isBlank()) return null
        val token = p.token ?: return null
        val key = p.server + "\n" + token
        cachedApi?.let { if (it.first == key) return it.second }
        return Api(p.server, token).also { cachedApi = key to it }
    }

    private suspend fun loop(ctx: Context) {
        var failures = 0
        while (scope.isActive) {
            val api = api(ctx)
            if (api == null) {
                _state.update { it.copy(connected = false) }
                return
            }
            try {
                val s = _state.value
                val p = api.items(s.session, after(), rev, wait = s.loaded)
                apply(ctx, p)
                failures = 0
            } catch (e: ApiException) {
                if (e.unauthorized) {
                    Prefs(ctx).clearSession()
                    Images.clear(ctx)
                    _state.value = SyncState(loggedOut = true)
                    SyncService.stop(ctx)
                    return
                }
                failures++
                _state.update { it.copy(connected = false, error = e.message) }
                delay(minOf(60_000L, 1_000L shl minOf(failures, 6)))
            }
        }
    }

    private suspend fun apply(ctx: Context, p: Poll) = lock.withLock {
        val old = _state.value
        val items = ClipList.merge(old.items, old.session, p)
        rev = p.rev
        _state.value = old.copy(items = items, session = p.session, you = p.you, loaded = true, connected = true, error = null)

        val prefs = Prefs(ctx)
        val fresh = ClipList.toNotify(p, prefs.seenTime, prefs.notifyMode)
        prefs.seenTime = ClipList.seenTime(p, prefs.seenTime)
        prefs.seenSession = p.session
        Images.prune(ctx, p.session, items)

        val newest = fresh.lastOrNull()
        if (newest != null && prefs.autoCopy) {
            try {
                Clipboard.copy(ctx, newest, p.session, Prefs(ctx).api(), toast = false)
            } catch (_: ApiException) {
                // gambar gagal diunduh: tetap ada tombol Salin di notifikasi
            }
        }
        if (!visible) {
            fresh.forEach { Notifier.show(ctx, it, p.session, copied = prefs.autoCopy && it == newest) }
        }
    }
}
