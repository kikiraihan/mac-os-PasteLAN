package id.local.pastelan.ui

import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import id.local.pastelan.Clip
import id.local.pastelan.Images
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Satu layar: kotak kirim di atas, riwayat server di bawah (terbaru di atas, sama dengan PWA).
 * Ketuk item = salin; tekan lama = menu (Salin, Bagikan, Hapus). Pengaturan lewat ikon ⚙.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(model: MainModel, openSettings: () -> Unit) {
    val state by model.state.collectAsState()
    val snack = remember { SnackbarHostState() }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val list = rememberLazyListState()

    LaunchedEffect(model.message) {
        model.message?.let {
            snack.showSnackbar(it)
            model.message = null
        }
    }
    LaunchedEffect(model.highlight, state.items) {
        val i = state.items.indexOfFirst { it.id == model.highlight }
        if (i >= 0) list.animateScrollToItem(i + 1)
    }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("PasteLAN")
                        Spacer(Modifier.width(10.dp))
                        Box(
                            Modifier.size(10.dp).clip(CircleShape).background(
                                when {
                                    state.connected -> Ok
                                    state.error != null -> MaterialTheme.colorScheme.error
                                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                                },
                            ).testTag("status"),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = openSettings) { Icon(Icons.Outlined.Settings, contentDescription = "Pengaturan") }
                },
                scrollBehavior = scroll,
            )
        },
        snackbarHost = { SnackbarHost(snack) },
    ) { pad ->
        LazyColumn(
            state = list,
            modifier = Modifier.fillMaxSize().padding(pad).imePadding(),
            contentPadding = PaddingValues(16.dp, 4.dp, 16.dp, 32.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { Composer(model) }
            if (state.error != null && !state.connected) {
                item { Text(state.error ?: "", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
            if (state.loaded && state.items.isEmpty()) {
                item {
                    Text(
                        "Belum ada kiriman. Copy di Mac (autosync) atau kirim dari sini — semua perangkat langsung menerimanya.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(24.dp),
                    )
                }
            }
            items(state.items, key = { state.session + it.id }) { clip ->
                ClipRow(model, clip, mine = clip.device == state.you, highlighted = clip.id == model.highlight)
            }
        }
    }
}

@Composable
private fun Composer(model: MainModel) {
    val ctx = LocalContext.current
    var text by rememberSaveable { mutableStateOf("") }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        uri?.let(model::sendImage)
    }
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = text, onValueChange = { text = it }, placeholder = { Text("Tulis atau tempel teks…") },
                modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp).testTag("compose"),
                shape = RoundedCornerShape(10.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = {
                    val clip = ctx.getSystemService(ClipboardManager::class.java)?.primaryClip
                    val uri = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                    val type = clip?.description?.takeIf { it.mimeTypeCount > 0 }?.getMimeType(0).orEmpty()
                    if (uri != null && type.startsWith("image/")) {
                        model.sendImage(uri) // gambar di clipboard HP → langsung kirim
                    } else {
                        val t = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
                        if (t.isBlank()) model.message = "Clipboard HP kosong" else text = t
                    }
                }) {
                    Icon(Icons.Outlined.ContentPaste, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Tempel")
                }
                TextButton(onClick = { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Icon(Icons.Outlined.Image, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Gambar")
                }
                Spacer(Modifier.weight(1f))
                FilledIconButton(
                    onClick = { model.sendText(text) { text = "" } },
                    enabled = text.isNotBlank() && !model.busy,
                    modifier = Modifier.testTag("send"),
                ) { Icon(Icons.AutoMirrored.Outlined.Send, contentDescription = "Kirim") }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ClipRow(model: MainModel, clip: Clip, mine: Boolean, highlighted: Boolean) {
    val ctx = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    val border = if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant

    Box {
        Surface(
            shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer,
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
                .border(if (highlighted) 2.dp else 1.dp, border, RoundedCornerShape(14.dp))
                .combinedClickable(onClick = { model.copy(clip) }, onLongClick = { menu = true })
                .testTag("clip-${clip.id}"),
        ) {
            Column(Modifier.padding(12.dp)) {
                Row {
                    Text(
                        (if (mine) "HP ini" else clip.from.ifBlank { "Perangkat lain" }) + " · " + timeLabel(clip.time),
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text(sizeLabel(clip.size), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.size(6.dp))
                if (clip.isImage) {
                    // null = sedang dimuat; Result.failure = gagal (tetap bisa disalin, diunduh ulang saat diketuk)
                    val bmp by produceState<Result<Bitmap>?>(null, clip.id) {
                        val b = model.imageFile(clip)?.let { withContext(Dispatchers.IO) { Images.thumbnail(it, 900) } }
                        value = if (b != null) Result.success(b) else Result.failure(Exception())
                    }
                    val loaded = bmp?.getOrNull()
                    if (loaded != null) {
                        Image(
                            loaded.asImageBitmap(), contentDescription = "Gambar dari ${clip.from}",
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp).clip(RoundedCornerShape(8.dp)),
                        )
                    } else {
                        Text(
                            if (bmp == null) "Gambar · memuat…" else "Gambar · pratinjau gagal dimuat (ketuk untuk menyalin)",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    Text(clip.text, maxLines = if (expanded) Int.MAX_VALUE else 8, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Salin") }, onClick = { menu = false; model.copy(clip) })
            if (!clip.isImage && (clip.text.lines().size > 8 || clip.text.length > 400)) {
                DropdownMenuItem(text = { Text(if (expanded) "Ringkas" else "Lihat semua") }, onClick = { menu = false; expanded = !expanded })
            }
            DropdownMenuItem(text = { Text("Bagikan…") }, onClick = {
                menu = false
                val send = Intent(Intent.ACTION_SEND).apply {
                    if (clip.isImage) {
                        type = clip.mime
                        putExtra(Intent.EXTRA_STREAM, model.shareUri(clip))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    } else {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, clip.text)
                    }
                }
                ctx.startActivity(Intent.createChooser(send, null))
            })
            DropdownMenuItem(text = { Text("Hapus", color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; confirmDelete = true })
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Hapus kiriman ini?") },
            text = { Text("Terhapus dari riwayat server dan semua perangkat.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; model.delete(clip) }) { Text("Hapus", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Batal") } },
        )
    }
}
