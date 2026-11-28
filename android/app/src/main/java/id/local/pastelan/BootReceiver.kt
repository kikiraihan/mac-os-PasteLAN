package id.local.pastelan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** HP menyala / aplikasi diperbarui: hidupkan lagi koneksi latar. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            SyncService.start(ctx.applicationContext)
        }
    }
}
