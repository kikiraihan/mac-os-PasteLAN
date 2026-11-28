package id.local.pastelan

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Notifikasi kiriman baru dari perangkat lain. Tombol **Salin** langsung memasukkan teks / gambar ke clipboard
 * tanpa membuka aplikasi (ActionReceiver); ketuk notifikasi = buka aplikasi dan salin (sama dengan PWA).
 */
object Notifier {
    const val CH_CLIP = "clip"
    const val CH_SYNC = "sync"

    /** Teks sepanjang ini ikut di tombol Salin; lebih panjang → diambil lagi dari server saat diketuk. */
    private const val MAX_EXTRA_TEXT = 60_000

    fun channels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(CH_CLIP, "Kiriman", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Teks & gambar yang dikirim dari Mac, browser, atau HP lain — dengan tombol Salin"
                },
                NotificationChannel(CH_SYNC, "Koneksi latar", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Tampil selama aplikasi tersambung ke server untuk menerima kiriman saat tertutup"
                    setShowBadge(false)
                },
            ),
        )
    }

    fun allowed(ctx: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun idFor(session: String, id: Long) = (session + "/" + id).hashCode()

    /** Cuplikan satu paragraf untuk judul / isi notifikasi. */
    fun preview(text: String, max: Int = 300): String {
        val one = text.trim().replace(Regex("\\s+"), " ")
        return if (one.length > max) one.take(max).trimEnd() + "…" else one
    }

    private fun copyAction(ctx: Context, clip: Clip, session: String): PendingIntent {
        val nid = idFor(session, clip.id)
        val i = Intent(ctx, ActionReceiver::class.java).apply {
            action = ActionReceiver.COPY
            putExtra("nid", nid)
            putExtra("session", session)
            putExtra("id", clip.id)
            if (!clip.isImage && clip.text.length <= MAX_EXTRA_TEXT) putExtra("text", clip.text)
        }
        return PendingIntent.getBroadcast(ctx, nid, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun openAction(ctx: Context, clip: Clip, session: String): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_COPY_ID, clip.id)
            putExtra(MainActivity.EXTRA_SESSION, session)
        }
        return PendingIntent.getActivity(ctx, idFor(session, clip.id), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** copied = sudah disalin otomatis (pengaturan "Salin otomatis"). Gambar diunduh dulu untuk pratinjau. */
    suspend fun show(ctx: Context, clip: Clip, session: String, copied: Boolean = false) {
        if (!allowed(ctx)) return
        val from = clip.from.ifBlank { "perangkat lain" }
        val b = NotificationCompat.Builder(ctx, CH_CLIP)
            .setSmallIcon(R.drawable.ic_stat)
            .setColor(0xFF007AFF.toInt())
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setWhen(clip.time)
            .setShowWhen(true)
            .setContentIntent(openAction(ctx, clip, session))
            // isi clipboard tidak ditampilkan di layar kunci (bisa berisi kode / password)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(ctx, CH_CLIP).setSmallIcon(R.drawable.ic_stat)
                    .setContentTitle("PasteLAN").setContentText("Kiriman baru dari $from").build(),
            )
        val status = if (copied) " · sudah disalin" else ""
        if (clip.isImage) {
            b.setContentTitle("Gambar dari $from$status").setContentText("Ketuk Salin untuk menyalin gambar")
            val bmp = try {
                Images.thumbnail(Images.ensure(ctx, Prefs(ctx).api(), session, clip))
            } catch (_: ApiException) {
                null
            }
            if (bmp != null) {
                b.setLargeIcon(bmp)
                b.setStyle(NotificationCompat.BigPictureStyle().bigPicture(bmp).bigLargeIcon(null as android.graphics.Bitmap?))
            }
        } else {
            b.setContentTitle("Dari $from$status")
                .setContentText(preview(clip.text, 120))
                .setStyle(NotificationCompat.BigTextStyle().bigText(preview(clip.text, 600)))
        }
        b.addAction(0, if (copied) "Salin lagi" else "Salin", copyAction(ctx, clip, session))
        try {
            NotificationManagerCompat.from(ctx).notify(idFor(session, clip.id), b.build())
        } catch (_: SecurityException) {
            // izin notifikasi dicabut di tengah jalan
        }
    }

    fun cancel(ctx: Context, id: Int) = NotificationManagerCompat.from(ctx).cancel(id)
}
