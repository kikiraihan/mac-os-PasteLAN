package id.local.pastelan

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * Cache gambar dari server (folder cache/images, tidak ikut backup). Hanya gambar yang masih ada di riwayat
 * server yang disimpan; sisanya dibuang setiap polling ([prune]) dan semuanya saat keluar ([clear]).
 */
object Images {
    private fun dir(ctx: Context) = File(ctx.cacheDir, "images")

    /** Nama file = potongan session + id, jadi item dari sesi riwayat lain tidak pernah tertukar. */
    fun file(ctx: Context, session: String, clip: Clip) =
        File(dir(ctx), "pastelan-${session.filter { it.isLetterOrDigit() }.take(12)}-${clip.id}.${clip.ext}")

    suspend fun ensure(ctx: Context, api: Api, session: String, clip: Clip): File {
        val f = file(ctx, session, clip)
        if (!f.exists()) api.image(clip.id, f)
        return f
    }

    fun uri(ctx: Context, f: File): Uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", f)

    /** Bitmap kecil untuk notifikasi / daftar (hemat memori: diperkecil ke ±[maxSide] px). */
    fun thumbnail(f: File, maxSide: Int = 1024): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = sample })
    } catch (_: Exception) {
        null
    }

    fun prune(ctx: Context, session: String, items: List<Clip>) {
        val keep = items.filter { it.isImage }.map { file(ctx, session, it).name }.toSet()
        dir(ctx).listFiles()?.forEach { if (it.name !in keep) it.delete() }
    }

    fun clear(ctx: Context) {
        dir(ctx).deleteRecursively()
    }
}

/** Salin ke clipboard HP. Android 13+ menampilkan konfirmasi sendiri; versi lama diberi toast. */
object Clipboard {
    fun copyText(ctx: Context, text: String, toast: Boolean = true) {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newPlainText("PasteLAN", text))
        if (toast) feedback(ctx, "Teks disalin")
    }

    fun copyImage(ctx: Context, f: File, toast: Boolean = true) {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newUri(ctx.contentResolver, "PasteLAN", uri(ctx, f)))
        if (toast) feedback(ctx, "Gambar disalin")
    }

    private fun uri(ctx: Context, f: File) = Images.uri(ctx, f)

    /** Salin satu item (gambar diunduh dulu bila belum ada di cache). */
    suspend fun copy(ctx: Context, clip: Clip, session: String, api: Api, toast: Boolean = true) {
        if (clip.isImage) {
            val f = Images.ensure(ctx, api, session, clip)
            main { copyImage(ctx, f, toast) }
        } else {
            main { copyText(ctx, clip.text, toast) }
        }
    }

    private fun feedback(ctx: Context, msg: String) {
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()
    }

    fun main(f: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) f() else Handler(Looper.getMainLooper()).post(f)
    }
}
