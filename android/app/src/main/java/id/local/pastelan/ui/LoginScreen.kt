package id.local.pastelan.ui

import android.content.ClipboardManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import id.local.pastelan.SetupLink

/**
 * Masuk dengan **link setup** (dari halaman admin / "Tambah HP" di Mac: https://server/#pair=…) — tanpa password.
 * Link di clipboard langsung terisi. Cara lama dengan password perangkat ada di balik "Masuk dengan password".
 */
@Composable
fun LoginScreen(model: MainModel, initialLink: String = "") {
    val ctx = LocalContext.current
    var link by rememberSaveable { mutableStateOf(initialLink) }
    var name by rememberSaveable { mutableStateOf(model.prefs.deviceName.ifBlank { model.defaultName() }) }
    var usePassword by rememberSaveable { mutableStateOf(false) }
    var server by rememberSaveable { mutableStateOf(model.prefs.server.removePrefix("https://")) }
    var password by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(Unit) {
        if (link.isBlank()) {
            // aplikasi sedang di depan → boleh membaca clipboard; hanya dipakai kalau isinya link setup PasteLAN
            val clip = ctx.getSystemService(ClipboardManager::class.java)?.primaryClip
            val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
            if (SetupLink.parse(text) != null) link = text.trim()
        }
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(Modifier.height(32.dp))
        Text("PasteLAN", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
        Text(
            "Copy-paste teks & gambar antara Mac, browser, dan HP ini lewat server PasteLAN milikmu.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        if (!usePassword) {
            OutlinedTextField(
                value = link, onValueChange = { link = it }, label = { Text("Link setup") },
                placeholder = { Text("https://server/#pair=…") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth().testTag("link"),
            )
            OutlinedButton(onClick = {
                val opts = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                GmsBarcodeScanning.getClient(ctx, opts).startScan()
                    .addOnSuccessListener { code ->
                        val raw = code.rawValue.orEmpty()
                        if (SetupLink.parse(raw) != null) {
                            link = raw
                            model.loginWithLink(raw, name)
                        } else {
                            model.loginError = "QR ini bukan link setup PasteLAN."
                        }
                    }
                    .addOnFailureListener {
                        model.loginError = "Pemindai QR tidak tersedia di HP ini (butuh Google Play services). Tempel link setup saja."
                    }
            }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.QrCodeScanner, null)
                Spacer(Modifier.width(8.dp))
                Text("Scan QR dari Mac")
            }
            Text(
                "Di Mac: menu PasteLAN → Tambah HP (scan QR)… lalu scan dengan tombol di atas. Atau di halaman admin " +
                    "server: Buat link setup → Salin link, lalu buka aplikasi ini (link langsung terisi). Sekali pakai, " +
                    "berlaku beberapa menit.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            OutlinedTextField(
                value = server, onValueChange = { server = it }, label = { Text("Alamat server") },
                placeholder = { Text("paste.contoh.id") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = password, onValueChange = { password = it }, label = { Text("Password perangkat") },
                singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        OutlinedTextField(
            value = name, onValueChange = { name = it.take(60) }, label = { Text("Nama perangkat") }, singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        model.loginError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
        Button(
            onClick = {
                if (usePassword) model.loginWithPassword(server, password, name) else model.loginWithLink(link, name)
            },
            enabled = !model.busy, modifier = Modifier.fillMaxWidth().height(48.dp),
        ) {
            if (model.busy) CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp) else Text("Masuk")
        }
        TextButton(onClick = { usePassword = !usePassword; model.loginError = null }, modifier = Modifier.fillMaxWidth()) {
            Text(if (usePassword) "Masuk dengan link setup" else "Masuk dengan password")
        }
    }
}
