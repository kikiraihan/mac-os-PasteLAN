package id.local.pastelan

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifier.channels(this)
    }
}
