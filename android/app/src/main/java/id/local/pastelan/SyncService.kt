package id.local.pastelan

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Notifikasi saat aplikasi tertutup: koneksi long-poll ke server PasteLAN tetap hidup di latar (tanpa Google / FCM,
 * isi clipboard hanya lewat server sendiri). Android mewajibkan notifikasi tetap untuk layanan seperti ini;
 * kanalnya "Koneksi latar" berprioritas minimum, bisa disembunyikan dari Pengaturan Android.
 */
class SyncService : Service() {
    private var holding = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = Prefs(applicationContext)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, Notifier.CH_SYNC)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Menunggu kiriman")
            .setContentText("Tersambung ke " + prefs.server.removePrefix("https://"))
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, 1, n, type)
        if (!prefs.loggedIn || !prefs.backgroundSync) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!holding) {
            holding = true
            Sync.acquire(applicationContext)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        if (holding) Sync.release()
        holding = false
        super.onDestroy()
    }

    companion object {
        fun start(ctx: Context) {
            val p = Prefs(ctx)
            if (!p.loggedIn || !p.backgroundSync || !Notifier.allowed(ctx)) return
            try {
                ctx.startForegroundService(Intent(ctx, SyncService::class.java))
            } catch (_: Exception) {
                // Android 12+: tidak boleh dimulai dari latar belakang → dimulai saat aplikasi dibuka.
            }
        }

        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, SyncService::class.java))
    }
}
