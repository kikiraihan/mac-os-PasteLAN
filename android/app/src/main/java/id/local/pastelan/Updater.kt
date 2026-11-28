package id.local.pastelan

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Cek versi terbaru di rilis GitHub (sama dengan aplikasi Mac). Aplikasi tidak memasang APK sendiri:
 * tombol "Unduh" membuka PasteLAN.apk / halaman rilis di browser, lalu Android memasangnya dan memastikan
 * tanda tangannya sama dengan versi yang terpasang.
 */
object Updater {
    const val REPO = "kikiraihan/mac-os-PasteLAN"

    data class Release(val version: String, val page: String, val apk: String?)

    fun current(ctx: Context): String =
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName.orEmpty().removeSuffix("-debug")

    /** "1.15.0" > "1.14.2"; bagian yang hilang dianggap 0. */
    fun newer(latest: String, current: String): Boolean {
        fun parts(v: String) = v.trim().removePrefix("v").split('.').map { p -> p.takeWhile { it.isDigit() }.toIntOrNull() ?: 0 }
        val a = parts(latest)
        val b = parts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    suspend fun latest(): Release = withContext(Dispatchers.IO) {
        val c = URL("https://api.github.com/repos/$REPO/releases/latest").openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 20_000
        c.setRequestProperty("Accept", "application/vnd.github+json")
        try {
            if (c.responseCode != 200) throw ApiException(c.responseCode, "Gagal memeriksa pembaruan (HTTP ${c.responseCode})")
            val o = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
            val assets = o.optJSONArray("assets")
            var apk: String? = null
            if (assets != null) {
                for (i in 0 until assets.length()) {
                    val a = assets.getJSONObject(i)
                    if (a.optString("name") == "PasteLAN.apk") apk = a.optString("browser_download_url").takeIf { it.startsWith("https://github.com/") }
                }
            }
            Release(o.optString("tag_name").removePrefix("v"), o.optString("html_url"), apk)
        } catch (e: IOException) {
            throw ApiException(0, "Gagal memeriksa pembaruan. Periksa koneksi internet.")
        } catch (e: org.json.JSONException) {
            throw ApiException(0, "Jawaban GitHub tidak dikenal")
        } finally {
            c.disconnect()
        }
    }
}
