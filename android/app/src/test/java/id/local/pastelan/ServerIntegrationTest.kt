package id.local.pastelan

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Klien Android (Api.kt + ClipList) terhadap server Go asli. Dijalankan oleh scripts/test-android.sh
 * (PASTELAN_URL / PASTELAN_PASS diisi); tanpa env itu tes dilewati.
 */
class ServerIntegrationTest {
    private val url = System.getenv("PASTELAN_URL").orEmpty()
    private val pass = System.getenv("PASTELAN_PASS").orEmpty()

    /** Kode pairing dari perangkat yang sudah masuk (sama dengan "Tambah HP (scan QR)…" di Mac). */
    private fun pairCode(token: String): String {
        val c = URL("$url/api/pair").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.setRequestProperty("X-PasteLAN", "1")
        c.setRequestProperty("Authorization", "Bearer $token")
        return JSONObject(c.inputStream.bufferedReader().readText()).getString("code")
    }

    // PNG 1×1
    private val png = byteArrayOf(
        -119, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, -60,
        -119, 0, 0, 0, 13, 73, 68, 65, 84, 120, -38, 99, -8, -1, -1, 63, 0, 5, -2, 2, -2, -89, 53, -127, -124, 0, 0, 0, 0,
        73, 69, 78, 68, -82, 66, 96, -126,
    )

    @Test fun fullFlow(): Unit = runBlocking {
        assumeTrue("PASTELAN_URL tidak diisi", url.isNotEmpty())
        val macLogin = Api(url, null).login(pass, "MacBook Tes")
        val mac = Api(url, macLogin.token)

        // HP masuk lewat link setup (tanpa password)
        val link = SetupLink.parse("$url/#pair=${pairCode(macLogin.token)}")!!
        assertEquals(url, link.server)
        val phoneLogin = Api(url, null).claimPair(link.code, "Pixel Tes")
        assertEquals("Pixel Tes", phoneLogin.deviceName)
        val phone = Api(link.server, phoneLogin.token)
        try {
            Api(url, null).claimPair(link.code, "HP lain")
            fail("kode pairing sekali pakai")
        } catch (e: ApiException) {
            assertEquals(401, e.status)
        }

        var p = phone.items("", 0, -1, wait = false)
        assertEquals(phoneLogin.deviceId, p.you)
        var list = ClipList.merge(emptyList(), "", p)
        var seen = ClipList.seenTime(p, -1)
        assertTrue(ClipList.toNotify(p, -1, Prefs.NOTIFY_ALL).isEmpty())

        // long-poll: HP menunggu, Mac copy (autosync, tanpa notifikasi) → HP langsung menerima
        val waiting = async(kotlinx.coroutines.Dispatchers.IO) { phone.items(p.session, list.maxOfOrNull { it.id } ?: 0, p.rev, wait = true) }
        delay(300)
        mac.sendText("kode OTP 123456", notify = false)
        p = waiting.await()
        assertEquals(listOf("kode OTP 123456"), p.items.map { it.text })
        assertEquals("MacBook Tes", p.items[0].from)
        assertEquals(listOf("kode OTP 123456"), ClipList.toNotify(p, seen, Prefs.NOTIFY_ALL).map { it.text })
        assertTrue("mode hanya-notifikasi", ClipList.toNotify(p, seen, Prefs.NOTIFY_MARKED).isEmpty())
        list = ClipList.merge(list, list.firstOrNull()?.let { p.session } ?: "", p)
        seen = ClipList.seenTime(p, seen)

        // ⌃ + klik di Mac (notify=1) → ditandai
        mac.sendText("dengan notifikasi", notify = true)
        p = phone.items(p.session, list.maxOf { it.id }, p.rev, wait = true)
        assertEquals(listOf("dengan notifikasi"), ClipList.toNotify(p, seen, Prefs.NOTIFY_MARKED).map { it.text })
        list = ClipList.merge(list, p.session, p)
        seen = ClipList.seenTime(p, seen)

        // kiriman HP sendiri tidak diberi tahu ke HP itu
        phone.sendText("dari HP", notify = false)
        p = phone.items(p.session, list.maxOf { it.id }, p.rev, wait = true)
        assertTrue(ClipList.toNotify(p, seen, Prefs.NOTIFY_ALL).isEmpty())
        list = ClipList.merge(list, p.session, p)

        // gambar: kirim dari HP, unduh lagi
        val imgId = phone.sendImage(png, "image/png", notify = false)
        p = phone.items(p.session, list.maxOf { it.id }, p.rev, wait = true)
        val img = p.items.single()
        assertEquals("image", img.kind)
        assertEquals("image/png", img.mime)
        val f = File.createTempFile("pastelan", ".png")
        phone.image(imgId, f)
        assertArrayEquals(png, f.readBytes())
        f.delete()
        list = ClipList.merge(list, p.session, p)
        assertEquals(4, list.size)

        // hapus satu → hilang di semua perangkat (ids / rev)
        mac.delete(list.last().id)
        val rev = p.rev
        p = phone.items(p.session, list.maxOf { it.id }, rev, wait = true)
        assertNotEquals(rev, p.rev)
        list = ClipList.merge(list, p.session, p)
        assertEquals(3, list.size)

        // hapus riwayat → session baru, daftar kosong
        mac.clear()
        val old = p.session
        p = phone.items(old, list.maxOf { it.id }, p.rev, wait = true)
        assertNotEquals(old, p.session)
        assertTrue(ClipList.merge(list, old, p).isEmpty())

        // keluar → token tidak berlaku lagi
        phone.logout()
        try {
            phone.items("", 0, -1, wait = false)
            fail("token dicabut")
        } catch (e: ApiException) {
            assertTrue(e.unauthorized)
        }
        mac.logout()
    }
}
