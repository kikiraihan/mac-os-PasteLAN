package id.local.pastelan

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ParseTest {
    @Test fun serverUrl() {
        assertEquals("https://paste.contoh.id", ServerUrl.normalize(" paste.contoh.id/ "))
        assertEquals("https://paste.contoh.id", ServerUrl.normalize("https://paste.contoh.id/admin"))
        assertEquals("https://paste.contoh.id", ServerUrl.normalize("https://paste.contoh.id/api/"))
        assertEquals("http://127.0.0.1:8080", ServerUrl.normalize("http://127.0.0.1:8080"))
        assertNull("HTTP biasa ditolak", ServerUrl.normalize("http://paste.contoh.id"))
        assertNull(ServerUrl.normalize(""))
    }

    @Test fun setupLink() {
        val p = SetupLink.parse("https://paste.contoh.id/#pair=Ab-9_x")!!
        assertEquals("https://paste.contoh.id", p.server)
        assertEquals("Ab-9_x", p.code)
        // ditempel bersama teks lain (mis. dari chat)
        assertEquals("kode", SetupLink.parse("Link PasteLAN:\nhttps://p.id/#pair=kode\nberlaku 5 menit")!!.code)
        assertNull(SetupLink.parse("https://paste.contoh.id/"))
        assertNull(SetupLink.parse("https://paste.contoh.id/#pair="))
        assertNull("karakter aneh ditolak", SetupLink.parse("https://p.id/#pair=a%20b"))
        assertNull("wajib HTTPS", SetupLink.parse("http://p.id/#pair=abc"))
    }

    private fun poll(vararg items: Clip, session: String = "s1", ids: Set<Long>? = null) =
        Poll(session, "hp", items.toList(), ids ?: items.map { it.id }.toSet(), 0)

    private fun clip(id: Long, device: String = "mac", time: Long = id * 1000, notify: Boolean = false) =
        Clip(id, "text", "isi $id", "", 5, time, "MacBook", device, notify)

    @Test fun parsePoll() {
        val o = JSONObject(
            """{"session":"abc","you":"d1","rev":3,"max":20,"ids":[1,2,3],
               "items":[{"id":2,"kind":"text","text":"halo","size":4,"time":1700,"from":"Mac","device":"d2","notify":true},
                        {"id":3,"kind":"image","mime":"image/jpeg","size":99,"time":1800,"from":"Mac","device":"d2"},
                        {"id":4,"kind":"file"}]}""",
        )
        val p = Parse.poll(o)
        assertEquals("abc", p.session)
        assertEquals("d1", p.you)
        assertEquals(3L, p.rev)
        assertEquals(setOf(1L, 2L, 3L), p.ids)
        assertEquals(listOf(2L, 3L), p.items.map { it.id }) // jenis tak dikenal dibuang
        assertTrue(p.items[0].notify)
        assertFalse(p.items[1].notify)
        assertEquals("jpg", p.items[1].ext)
    }

    @Test fun mergeList() {
        val a = ClipList.merge(emptyList(), "", poll(clip(1), clip(2)))
        assertEquals(listOf(2L, 1L), a.map { it.id }) // terbaru di atas
        // item baru + item 1 dihapus dari server
        val b = ClipList.merge(a, "s1", poll(clip(3), ids = setOf(2, 3)))
        assertEquals(listOf(3L, 2L), b.map { it.id })
        // session berganti (server restart / riwayat dihapus) → daftar lama dibuang
        val c = ClipList.merge(b, "s1", poll(clip(1), session = "s2"))
        assertEquals(listOf(1L), c.map { it.id })
    }

    @Test fun notifyRules() {
        val p = poll(clip(1, time = 100), clip(2, device = "hp", time = 200), clip(3, time = 300, notify = true))
        assertTrue("baru masuk: item lama tidak diberi tahu", ClipList.toNotify(p, -1, Prefs.NOTIFY_ALL).isEmpty())
        assertEquals("kiriman HP ini sendiri tidak", listOf(1L, 3L), ClipList.toNotify(p, 0, Prefs.NOTIFY_ALL).map { it.id })
        assertEquals(listOf(3L), ClipList.toNotify(p, 150, Prefs.NOTIFY_ALL).map { it.id })
        assertEquals("mode hanya-notifikasi", listOf(3L), ClipList.toNotify(p, 0, Prefs.NOTIFY_MARKED).map { it.id })
        assertEquals(300L, ClipList.seenTime(p, -1))
        assertEquals(0L, ClipList.seenTime(poll(), -1))
        val many = poll(*(1L..20L).map { clip(it) }.toTypedArray())
        assertEquals("maksimal 5 notifikasi sekaligus", (16L..20L).toList(), ClipList.toNotify(many, 0, Prefs.NOTIFY_ALL).map { it.id })
    }

    @Test fun updaterVersions() {
        assertTrue(Updater.newer("1.15.0", "1.14.9"))
        assertTrue(Updater.newer("v2.0", "1.99.99"))
        assertFalse(Updater.newer("1.15.0", "1.15.0"))
        assertFalse(Updater.newer("1.14.1", "1.15.0"))
    }

    @Test fun preview() {
        assertEquals("a b c", Notifier.preview("  a\n\n b\tc  "))
        assertEquals("abc…", Notifier.preview("abcdef", 3))
    }
}
