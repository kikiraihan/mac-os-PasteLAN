package id.local.pastelan

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/** Kesalahan dari server (pesan sudah berbahasa Indonesia) atau jaringan (status 0). */
class ApiException(val status: Int, message: String) : Exception(message) {
    val unauthorized get() = status == 401
}

/** Satu isi clipboard di server (teks / gambar). Isi gambar diambil terpisah lewat /api/image/{id}. */
data class Clip(
    val id: Long,
    val kind: String, // "text" / "image"
    val text: String,
    val mime: String,
    val size: Int,
    val time: Long, // ms sejak epoch (jam server)
    val from: String,
    val device: String,
    val notify: Boolean, // dikirim dengan notifikasi (⌃ + klik di Mac)
) {
    val isImage get() = kind == "image"
    val ext get() = mime.removePrefix("image/").replace("jpeg", "jpg").ifBlank { "png" }
}

/** Jawaban polling /api/items. */
data class Poll(
    val session: String,
    val you: String,
    val items: List<Clip>,
    val ids: Set<Long>,
    val rev: Long,
)

data class Login(val token: String, val deviceId: String, val deviceName: String)

object ServerUrl {
    /** "paste.contoh.id" → "https://paste.contoh.id"; buang "/", "/api", "/admin" di ujung. null = tidak valid. */
    fun normalize(raw: String): String? {
        var s = raw.trim().substringBefore('#').substringBefore('?').trimEnd('/')
        if (s.isEmpty()) return null
        if (!s.contains("://")) s = "https://$s"
        s = s.removeSuffix("/api").removeSuffix("/admin").trimEnd('/')
        return try {
            val u = URI(s)
            val scheme = u.scheme?.lowercase()
            val host = u.host ?: return null
            val local = host == "localhost" || host == "10.0.2.2" || host == "127.0.0.1"
            if (scheme != "https" && !(scheme == "http" && local)) null else s
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Link setup dari admin / QR dari Mac: `https://server/#pair=<kode>` (sama dengan PWA & aplikasi Mac).
 * Kode sekali pakai → token perangkat sendiri, tanpa mengetik password.
 */
object SetupLink {
    data class Parsed(val server: String, val code: String)

    fun parse(raw: String): Parsed? {
        val s = raw.trim().lineSequence().map { it.trim() }.firstOrNull { "#" in it && "pair=" in it } ?: return null
        val frag = s.substringAfter('#', "")
        val code = frag.split('&').firstOrNull { it.startsWith("pair=") }?.removePrefix("pair=")?.trim().orEmpty()
        if (code.isEmpty() || code.length > 200 || !code.all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
        val server = ServerUrl.normalize(s.substringBefore('#')) ?: return null
        return Parsed(server, code)
    }
}

/**
 * Klien HTTP ke server PasteLAN. Semua request membawa header `X-PasteLAN: 1` (wajib server) dan token
 * perangkat (`Authorization: Bearer`). Fungsi suspend — dijalankan di Dispatchers.IO.
 */
class Api(val base: String, private val token: String?) {

    private fun conn(method: String, path: String, timeoutMs: Int): HttpURLConnection {
        val c = try {
            URL("$base/api$path").openConnection() as HttpURLConnection
        } catch (e: IOException) { // termasuk MalformedURLException
            throw ApiException(0, "Alamat server tidak valid")
        }
        c.requestMethod = method
        c.connectTimeout = 15_000
        c.readTimeout = timeoutMs
        c.instanceFollowRedirects = false
        c.useCaches = false
        c.setRequestProperty("X-PasteLAN", "1")
        c.setRequestProperty("Accept", "application/json")
        token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
        return c
    }

    private fun readError(c: HttpURLConnection, code: Int): ApiException {
        val text = c.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        val msg = try {
            JSONObject(text).optString("error")
        } catch (_: Exception) {
            ""
        }
        return ApiException(code, msg.ifBlank { "HTTP $code" })
    }

    /** body: JSONObject (JSON) atau ByteArray (isi mentah: teks / gambar). */
    private suspend fun request(method: String, path: String, body: Any? = null, contentType: String = "application/json", timeoutMs: Int = 30_000): JSONObject =
        withContext(Dispatchers.IO) {
            val c = conn(method, path, timeoutMs)
            try {
                val bytes = when (body) {
                    null -> null
                    is JSONObject -> body.toString().toByteArray()
                    is ByteArray -> body
                    else -> error("jenis body tidak dikenal")
                }
                if (bytes != null) {
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", contentType)
                    c.setFixedLengthStreamingMode(bytes.size)
                    c.outputStream.use { it.write(bytes) }
                }
                val code = c.responseCode
                if (code !in 200..299) throw readError(c, code)
                val text = c.inputStream.bufferedReader().use { it.readText() }
                if (text.isBlank()) JSONObject() else JSONObject(text)
            } catch (e: IOException) {
                throw ApiException(0, "Tidak bisa terhubung ke server. Periksa koneksi internet.")
            } catch (e: org.json.JSONException) {
                throw ApiException(0, "Jawaban server tidak dikenal (bukan server PasteLAN?)")
            } finally {
                c.disconnect()
            }
        }

    // --- akun ---------------------------------------------------------------------

    suspend fun claimPair(code: String, name: String) =
        Parse.login(request("POST", "/pair/claim", JSONObject().put("code", code).put("name", name).put("client", "hp")))

    suspend fun login(password: String, name: String) =
        Parse.login(request("POST", "/login", JSONObject().put("password", password).put("name", name).put("client", "hp")))

    suspend fun logout() = request("POST", "/logout")

    // --- riwayat ------------------------------------------------------------------

    /** Long-poll: wait=true → server menahan jawaban sampai ada perubahan (maks. ±25 detik). */
    suspend fun items(session: String, after: Long, rev: Long, wait: Boolean): Poll {
        val q = "/items?s=${enc(session)}&after=$after&r=$rev" + if (wait) "&wait=1" else ""
        return Parse.poll(request("GET", q, timeoutMs = if (wait) 45_000 else 20_000))
    }

    suspend fun sendText(text: String, notify: Boolean) =
        request("POST", "/text" + if (notify) "?notify=1" else "", text.toByteArray(), "text/plain; charset=utf-8").optLong("id")

    suspend fun sendImage(bytes: ByteArray, mime: String, notify: Boolean) =
        request("POST", "/image" + if (notify) "?notify=1" else "", bytes, mime, timeoutMs = 120_000).optLong("id")

    suspend fun delete(id: Long) = request("DELETE", "/items/$id")
    suspend fun clear() = request("DELETE", "/items")

    /** Unduh isi gambar ke [dest] (ditulis lewat file sementara supaya tidak pernah setengah jadi). */
    suspend fun image(id: Long, dest: File) = withContext(Dispatchers.IO) {
        val c = conn("GET", "/image/$id", 120_000)
        try {
            val code = c.responseCode
            if (code != 200) throw readError(c, code)
            dest.parentFile?.mkdirs()
            val tmp = File(dest.path + ".part")
            c.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
            if (!tmp.renameTo(dest)) throw IOException("gagal menyimpan")
        } catch (e: IOException) {
            throw ApiException(0, "Gagal mengunduh gambar. Periksa koneksi internet.")
        } finally {
            c.disconnect()
        }
    }

    companion object {
        fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8")
    }
}

/** Pembacaan JSON manual (tanpa refleksi) — diuji di ParseTest. */
object Parse {
    fun login(o: JSONObject): Login {
        val d = o.optJSONObject("device") ?: JSONObject()
        val token = o.optString("token")
        if (token.isBlank()) throw ApiException(0, "Jawaban server tidak dikenal (bukan server PasteLAN?)")
        return Login(token, d.optString("id"), d.optString("name"))
    }

    fun clip(o: JSONObject) = Clip(
        id = o.optLong("id"),
        kind = o.optString("kind"),
        text = o.optString("text"),
        mime = o.optString("mime"),
        size = o.optInt("size"),
        time = o.optLong("time"),
        from = o.optString("from"),
        device = o.optString("device"),
        notify = o.optBoolean("notify"),
    )

    fun poll(o: JSONObject): Poll {
        val items = o.optJSONArray("items") ?: JSONArray()
        val ids = o.optJSONArray("ids") ?: JSONArray()
        return Poll(
            session = o.optString("session"),
            you = o.optString("you"),
            items = (0 until items.length()).map { clip(items.getJSONObject(it)) }.filter { it.kind == "text" || it.kind == "image" },
            ids = (0 until ids.length()).map { ids.getLong(it) }.toSet(),
            rev = o.optLong("rev", -1),
        )
    }
}
