package id.local.pastelan

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Pengaturan lokal. Token perangkat disimpan terenkripsi AES-GCM dengan kunci di Android Keystore
 * (kunci tidak bisa dikeluarkan dari perangkat; data aplikasi tidak ikut backup — allowBackup=false).
 * Isi clipboard tidak pernah disimpan di sini.
 */
class Prefs(context: Context) {
    private val sp: SharedPreferences = context.getSharedPreferences("pastelan", Context.MODE_PRIVATE)

    var server: String
        get() = sp.getString("server", "") ?: ""
        set(v) = sp.edit().putString("server", v).apply()

    var token: String?
        get() = sp.getString("token", null)?.let { Secure.decrypt(it) }
        set(v) = sp.edit().apply { if (v == null) remove("token") else putString("token", Secure.encrypt(v)) }.apply()

    var deviceName: String
        get() = sp.getString("device_name", "") ?: ""
        set(v) = sp.edit().putString("device_name", v).apply()

    /** Notifikasi saat aplikasi tertutup: layanan latar depan long-poll. */
    var backgroundSync: Boolean
        get() = sp.getBoolean("bg_sync", true)
        set(v) = sp.edit().putBoolean("bg_sync", v).apply()

    /** "all" = semua kiriman dari perangkat lain; "notify" = hanya yang dikirim dengan notifikasi (⌃ + klik di Mac). */
    var notifyMode: String
        get() = sp.getString("notify_mode", NOTIFY_ALL) ?: NOTIFY_ALL
        set(v) = sp.edit().putString("notify_mode", v).apply()

    /** Kiriman baru dari perangkat lain langsung masuk clipboard HP. */
    var autoCopy: Boolean
        get() = sp.getBoolean("auto_copy", false)
        set(v) = sp.edit().putBoolean("auto_copy", v).apply()

    /** Kirim dari HP dengan notifikasi ke HP / PWA lain (sama dengan ⌃ + klik di Mac). */
    var sendNotify: Boolean
        get() = sp.getBoolean("send_notify", false)
        set(v) = sp.edit().putBoolean("send_notify", v).apply()

    /** Sesi riwayat server + waktu (jam server) item terbaru yang sudah diketahui → tidak memberi tahu item lama lagi. */
    var seenSession: String
        get() = sp.getString("seen_session", "") ?: ""
        set(v) = sp.edit().putString("seen_session", v).apply()

    var seenTime: Long
        get() = sp.getLong("seen_time", -1)
        set(v) = sp.edit().putLong("seen_time", v).apply()

    val loggedIn get() = server.isNotBlank() && token != null

    fun api() = Api(server, token)

    fun clearSession() {
        sp.edit().remove("token").remove("seen_session").remove("seen_time").apply()
    }

    companion object {
        const val NOTIFY_ALL = "all"
        const val NOTIFY_MARKED = "notify"
    }
}

private object Secure {
    private const val ALIAS = "pastelan-token"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    fun encrypt(plain: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(plain.toByteArray())
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    fun decrypt(stored: String): String? = try {
        val raw = Base64.decode(stored, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, 12))
        String(c.doFinal(raw, 12, raw.size - 12))
    } catch (_: Exception) {
        null // kunci hilang (mis. data dipulihkan ke HP lain): harus masuk lagi
    }
}
