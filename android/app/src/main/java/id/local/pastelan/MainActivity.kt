package id.local.pastelan

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import id.local.pastelan.ui.HomeScreen
import id.local.pastelan.ui.LoginScreen
import id.local.pastelan.ui.MainModel
import id.local.pastelan.ui.PasteLANTheme
import id.local.pastelan.ui.SettingsScreen

class MainActivity : ComponentActivity() {
    private val model: MainModel by viewModels()
    private var setupLink by mutableStateOf("")
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        SyncService.start(applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) handle(intent)
        setContent {
            PasteLANTheme {
                Surface(Modifier.fillMaxSize()) {
                    val state by model.state.collectAsState()
                    LaunchedEffect(state.loggedOut) { if (state.loggedOut && model.loggedIn) model.onLoggedOut() }
                    var settings by rememberSaveable { mutableStateOf(false) }
                    when {
                        !model.loggedIn -> LoginScreen(model, setupLink)
                        settings -> SettingsScreen(model) { settings = false }
                        else -> HomeScreen(model) { settings = true }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Dibuka dari notifikasi (salin item itu) atau dari Bagikan dengan link setup (belum masuk). */
    private fun handle(i: Intent?) {
        i ?: return
        val id = i.getLongExtra(EXTRA_COPY_ID, 0)
        val session = i.getStringExtra(EXTRA_SESSION).orEmpty()
        if (id > 0 && model.loggedIn) model.copyFromNotification(session, id)
        i.getStringExtra(EXTRA_SETUP_LINK)?.let { setupLink = it }
    }

    override fun onStart() {
        super.onStart()
        Sync.visible = true
        if (model.loggedIn) {
            if (Build.VERSION.SDK_INT >= 33 && !Notifier.allowed(this)) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
            model.start()
            if (model.update == null) model.checkUpdate(manual = false)
        }
    }

    override fun onStop() {
        // Koneksi tetap jalan lewat SyncService (kalau diizinkan); yang dipegang layar ini dilepas.
        Sync.visible = false
        model.stop()
        super.onStop()
    }

    companion object {
        const val EXTRA_COPY_ID = "copyId"
        const val EXTRA_SESSION = "session"
        const val EXTRA_SETUP_LINK = "setupLink"
    }
}
