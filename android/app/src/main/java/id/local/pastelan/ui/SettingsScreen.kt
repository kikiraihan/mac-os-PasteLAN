package id.local.pastelan.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import id.local.pastelan.Prefs
import id.local.pastelan.Updater

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: MainModel, close: () -> Unit) {
    val ctx = LocalContext.current
    val p = model.prefs
    var bg by remember { mutableStateOf(p.backgroundSync) }
    var mode by remember { mutableStateOf(p.notifyMode) }
    var autoCopy by remember { mutableStateOf(p.autoCopy) }
    var sendNotify by remember { mutableStateOf(p.sendNotify) }
    var confirm by remember { mutableStateOf<String?>(null) } // "logout" / "clear"
    BackHandler(onBack = close)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Pengaturan") },
                navigationIcon = { IconButton(onClick = close) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Kembali") } },
            )
        },
    ) { pad ->
        LazyColumn(Modifier.fillMaxSize().padding(pad), contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 32.dp)) {
            item {
                Section("Notifikasi") {
                    SwitchRow(
                        "Terima saat aplikasi ditutup",
                        "Koneksi langsung ke server (tanpa Google). Android menampilkan notifikasi tetap \"Menunggu kiriman\".",
                        bg,
                    ) { bg = it; model.setBackgroundSync(it) }
                    HorizontalDivider()
                    Radio("Semua kiriman dari perangkat lain", "Termasuk copy biasa dari Mac (autosync)", mode == Prefs.NOTIFY_ALL) {
                        mode = Prefs.NOTIFY_ALL; p.notifyMode = mode
                    }
                    Radio("Hanya kiriman dengan notifikasi", "Di Mac: tahan ⌃ (Control) saat mengklik clip di menu", mode == Prefs.NOTIFY_MARKED) {
                        mode = Prefs.NOTIFY_MARKED; p.notifyMode = mode
                    }
                    HorizontalDivider()
                    SwitchRow(
                        "Salin otomatis",
                        "Kiriman baru langsung masuk clipboard HP (tombol Salin tetap ada di notifikasi).",
                        autoCopy,
                    ) { autoCopy = it; p.autoCopy = it }
                    BatteryRow()
                }
            }
            item {
                Section("Kirim") {
                    SwitchRow(
                        "Beri notifikasi ke HP lain",
                        "Kiriman dari HP ini memunculkan notifikasi di HP / PWA lain (sama dengan ⌃ + klik di Mac).",
                        sendNotify,
                    ) { sendNotify = it; p.sendNotify = it }
                }
            }
            item {
                Section("Akun") {
                    Info("Server", p.server.removePrefix("https://"))
                    Info("Nama perangkat", p.deviceName)
                    HorizontalDivider()
                    Action("Hapus riwayat di semua perangkat", danger = true) { confirm = "clear" }
                    Action("Keluar dari server", danger = true) { confirm = "logout" }
                }
            }
            item {
                Section("Tentang") {
                    Info("Versi", Updater.current(ctx))
                    val u = model.update
                    if (u != null) {
                        Action("Unduh versi ${u.version}") {
                            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u.apk ?: u.page)))
                        }
                    } else {
                        Action("Periksa pembaruan") { model.checkUpdate(manual = true) }
                    }
                }
            }
        }
    }

    when (confirm) {
        "logout" -> Confirm(
            "Keluar dari server?", "Token HP ini dicabut. Untuk masuk lagi perlu link setup / password baru.", "Keluar",
            onYes = { model.logout(); close() }, onNo = { confirm = null },
        )
        "clear" -> Confirm(
            "Hapus semua riwayat?", "Semua kiriman di server dihapus, di semua perangkat.", "Hapus",
            onYes = { model.clearAll(); confirm = null }, onNo = { confirm = null },
        )
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Text(
        title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, top = 20.dp, bottom = 8.dp),
    )
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth()) { content() }
    }
}

@Composable
private fun SwitchRow(title: String, hint: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Switch) { onChange(!checked) }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title)
            Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Radio(title: String, hint: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected, role = Role.RadioButton, onClick = onClick).padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null, modifier = Modifier.padding(horizontal = 10.dp))
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun Info(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(14.dp)) {
        Text(title, Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Action(title: String, danger: Boolean = false, onClick: () -> Unit) {
    Text(
        title, color = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(14.dp),
    )
}

/** Tanpa ini sebagian HP (Xiaomi, Samsung, dsb.) memutus koneksi latar → notifikasi telat / tidak muncul. */
@SuppressLint("BatteryLife")
@Composable
private fun BatteryRow() {
    val ctx = LocalContext.current
    val pm = ctx.getSystemService(PowerManager::class.java)
    if (pm == null || pm.isIgnoringBatteryOptimizations(ctx.packageName)) return
    HorizontalDivider()
    Action("Izinkan berjalan tanpa pembatasan baterai") {
        ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)))
    }
}

@Composable
private fun Confirm(title: String, text: String, yes: String, onYes: () -> Unit, onNo: () -> Unit) {
    AlertDialog(
        onDismissRequest = onNo,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = onYes) { Text(yes, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onNo) { Text("Batal") } },
    )
}
