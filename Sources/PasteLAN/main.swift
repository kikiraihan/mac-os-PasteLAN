// PasteLAN — berbagi copy-paste (teks & gambar) antara Mac dan HP lewat server PasteLAN milik sendiri.
//   • Server kecil (folder server/, Go) di VPS Anda, lewat HTTPS; HP memakai halaman web / PWA dari server itu
//   • Mac login sekali dengan password server → token perangkat disimpan di Keychain
//   • HP → Mac : kirim teks / gambar dari HP → langsung masuk clipboard Mac
//   • Mac → HP : setiap copy di Mac muncul otomatis di HP, tinggal tekan "Salin"
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import CryptoKit
import ImageIO
import Network
import CoreImage
import Security
import SystemConfiguration
import ServiceManagement

// MARK: - Utilitas

func json(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

/// 16 byte acak (SystemRandomNumberGenerator = kriptografis) → 32 karakter hex
func randomHex(_ bytes: Int = 16) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

/// Base64 versi URL (tanpa + / =) → aman ditaruh di link & header
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func fromB64url(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)
}

func symbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "PasteLAN")
    img?.isTemplate = true // ikut tema terang/gelap menu bar
    return img
}

/// Ikon menu bar: SF Symbol sedikit lebih kecil dari default supaya pas di item selebar 18 pt
/// Tanda kecil di kanan bawah ikon menu bar: titik penuh = sinkron aktif & tersambung, lingkaran = sinkron aktif
/// tapi sedang menghubungkan / terputus, tanpa tanda = sinkron mati (clipboard manager saja)
enum BarBadge { case none, on, waiting }

func barIcon(_ name: String, badge: BarBadge = .none) -> NSImage? {
    guard let base = symbol(name)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) else {
        return nil
    }
    base.isTemplate = true
    guard badge != .none else { return base }
    let dot: CGFloat = 5.5
    let size = NSSize(width: base.size.width + 3.5, height: max(base.size.height, 16))
    let img = NSImage(size: size, flipped: false) { r in
        base.draw(in: NSRect(x: 0, y: (r.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
        let rect = NSRect(x: r.width - dot, y: 1, width: dot, height: dot)
        NSColor.black.set() // gambar template: warna asli diabaikan, macOS mewarnai sesuai tema menu bar
        if badge == .on {
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.7, dy: 0.7))
            ring.lineWidth = 1.2
            ring.stroke()
        }
        return true
    }
    img.isTemplate = true
    return img
}

func fileExt(_ mime: String?) -> String {
    switch mime ?? "" {
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/heic": return "heic"
    case "image/webp": return "webp"
    case "image/tiff": return "tiff"
    default: return "png"
    }
}

/// Cuplikan satu baris isi clipboard untuk menu (gaya Clipy: teks apa adanya, dipotong dengan "…")
func clipTitle(kind: String, text: String?, mime: String?, size: Int) -> String {
    if kind == "image" { return "🖼 Gambar \(fileExt(mime).uppercased()), \(byteString(size))" }
    var line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .newlines).first ?? ""
    line = line.replacingOccurrences(of: "\t", with: " ")
    if line.count > 45 { line = String(line.prefix(45)) + "…" }
    return line.isEmpty ? "(spasi kosong)" : line
}

func byteString(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// Nama Mac (mis. "MacBook Air Kiki") untuk ditampilkan di halaman HP
func computerName() -> String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}

// MARK: - QR code

func qrImage(_ text: String, points: CGFloat) -> NSImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage else { return nil }
    // diperbesar dengan kelipatan bulat (2× untuk layar Retina) supaya modul QR tetap tajam
    let scale = max(1, (points * 2 / out.extent.width).rounded(.down))
    let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg = CIContext().createCGImage(big, from: big.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
}

// MARK: - Clipboard Mac

struct PasteContent {
    let kind: String
    let text: String?
    let data: Data?
    let mime: String?
}

final class Clipboard {
    let pb = NSPasteboard.general
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    var onChange: (() -> Void)?

    let maxText = 2 * 1024 * 1024
    let maxImage = 30 * 1024 * 1024
    static let imageExts = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp"]
    /// Format gambar dari HP yang diterima; MIME lain disimpan sebagai image/png (mis. SVG tidak pernah disajikan ulang)
    static let imageMimes = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/tiff"]
    static let maxPixels = 100_000_000 // 100 megapiksel

    /// Lebar × tinggi dari header gambar saja (tanpa decode penuh) → "bom dekompresi" ditolak sebelum dibuka
    static func pixelCount(_ data: Data) -> Int? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return w * h
    }

    /// macOS tidak punya notifikasi perubahan clipboard → cek changeCount (satu integer, sangat ringan)
    func startWatching() {
        guard timer == nil else { return }
        lastCount = pb.changeCount
        let t = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.4 // boleh telat sedikit → macOS bisa menggabungkan wake-up, hemat energi
        RunLoop.main.add(t, forMode: .common) // tetap jalan saat menu sedang terbuka
        timer = t
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        onChange?()
    }

    /// Dipanggil setelah PasteLAN sendiri menulis clipboard → tidak dikirim balik ke HP
    func markOwnWrite() { lastCount = pb.changeCount }

    func writeText(_ s: String) {
        pb.clearContents()
        pb.setString(s, forType: .string)
        markOwnWrite()
    }

    /// TIFF (dibaca semua aplikasi) + format asli (PNG/JPEG) supaya kualitas tidak turun
    func writeImage(_ data: Data, mime: String?) -> Bool {
        guard let px = Clipboard.pixelCount(data), px <= Clipboard.maxPixels,
              let img = NSImage(data: data), img.isValid else { return false }
        pb.clearContents()
        pb.writeObjects([img])
        let original: NSPasteboard.PasteboardType? =
            mime == "image/png" ? .png : mime == "image/jpeg" ? NSPasteboard.PasteboardType("public.jpeg") : nil
        if let original {
            pb.addTypes([original], owner: nil)
            pb.setData(data, forType: original)
        }
        markOwnWrite()
        return true
    }

    /// Isi clipboard Mac saat ini, atau nil kalau kosong / rahasia / tidak didukung
    func read() -> PasteContent? {
        let types = pb.types ?? []
        // isi rahasia (password manager) & sementara tidak dikirim — konvensi nspasteboard.org
        let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if types.contains(where: { secret.contains($0.rawValue) }) { return nil }

        // file yang di-copy dari Finder: kirim isinya kalau gambar, selain itu lewati (bukan nama file)
        if types.contains(.fileURL) {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard let u = urls.first(where: { Clipboard.imageExts.contains($0.pathExtension.lowercased()) }) else { return nil }
            return imageFile(u)
        }

        let text = pb.string(forType: .string)
        let hasImage = pb.availableType(from: [.png, .tiff]) != nil
        // teks + gambar (mis. sel Excel) → teks menang, kecuali teksnya hanya URL (kasus "Copy Image" di browser)
        if let text, !text.isEmpty, !(hasImage && Clipboard.isSingleURL(text)) {
            guard text.utf8.count <= maxText else { return nil }
            return PasteContent(kind: "text", text: text, data: nil, mime: nil)
        }
        if let png = pb.data(forType: .png), png.count <= maxImage {
            return PasteContent(kind: "image", text: nil, data: png, mime: "image/png")
        }
        if hasImage, let img = NSImage(pasteboard: pb), let png = Clipboard.encode(img, as: .png), png.count <= maxImage {
            return PasteContent(kind: "image", text: nil, data: png, mime: "image/png")
        }
        return nil
    }

    static func isSingleURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(where: { $0.isWhitespace }) && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }

    /// PNG/JPEG/GIF dikirim apa adanya; HEIC/TIFF/dll. diubah ke JPEG supaya bisa tampil di browser Android
    private func imageFile(_ u: URL) -> PasteContent? {
        guard let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxImage,
              let data = try? Data(contentsOf: u) else { return nil }
        switch u.pathExtension.lowercased() {
        case "png": return PasteContent(kind: "image", text: nil, data: data, mime: "image/png")
        case "jpg", "jpeg": return PasteContent(kind: "image", text: nil, data: data, mime: "image/jpeg")
        case "gif": return PasteContent(kind: "image", text: nil, data: data, mime: "image/gif")
        default:
            guard let img = NSImage(data: data), let jpg = Clipboard.encode(img, as: .jpeg) else { return nil }
            return PasteContent(kind: "image", text: nil, data: jpg, mime: "image/jpeg")
        }
    }

    static func encode(_ img: NSImage, as type: NSBitmapImageRep.FileType) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let props: [NSBitmapImageRep.PropertyKey: Any] = type == .jpeg ? [.compressionFactor: 0.9] : [:]
        return rep.representation(using: type, properties: props)
    }
}

// MARK: - Riwayat clipboard Mac (clipboard manager; di memori, salinannya disimpan di disk kecuali dimatikan)

/// Satu clip di riwayat Mac. Kelas (bukan struct) supaya status kirimnya bisa diperbarui setelah server menjawab.
final class LocalClip {
    let id: Int
    let kind: String   // "text" / "image"
    let text: String?
    var data: Data?    // isi gambar; nil = gambar di server yang belum diambil
    let mime: String?
    let size: Int
    var from: String   // "" = Mac ini, selain itu nama perangkat pengirim
    var time: Date
    var serverID: Int? // id item di server PasteLAN (kalau ada di sana)
    var synced: Bool   // sudah dikirim ke / diterima dari server atau HP

    init(id: Int, kind: String, text: String?, data: Data?, mime: String?, size: Int, from: String, time: Date,
         serverID: Int?, synced: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.data = data
        self.mime = mime
        self.size = size
        self.from = from
        self.time = time
        self.serverID = serverID
        self.synced = synced
    }

    /// Cuplikan satu baris untuk menu & tabel
    var title: String { clipTitle(kind: kind, text: text, mime: mime, size: size) }
    var source: String { from.isEmpty ? "Mac ini" : from }
    var status: String { !from.isEmpty ? "Diterima" : synced ? "Terkirim" : "Hanya di Mac" }
    var pending: Bool { from.isEmpty && !synced }

    /// Cocok dengan kata pencarian (isi teks; gambar cocok dengan "gambar" / jenis filenya)
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let hay = kind == "image" ? "gambar image \(fileExt(mime))" : (text ?? "")
        return hay.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func same(kind k: String, text t: String?, data d: Data?, serverID sid: Int?) -> Bool {
        guard k == kind else { return false }
        if kind == "text" { return t == text }
        if let sid, sid == serverID { return true }
        if let d, let data { return d == data }
        return false
    }
}

/// Riwayat clipboard Mac: semua copy di Mac (juga saat sinkron mati) + kiriman dari perangkat lain. Terbaru di depan.
final class History {
    private(set) var items: [LocalClip] = []
    private(set) var nextID = 1
    let maxImageBytes = 200 * 1024 * 1024
    var limit = 15 {
        didSet {
            trim()
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    /// Isi yang sama dengan clip yang sudah ada → clip itu dipakai lagi (naik ke atas kalau `bump`)
    @discardableResult
    func add(kind: String, text: String?, data: Data?, mime: String?, size: Int, from: String, synced: Bool,
             serverID: Int? = nil, time: Date = Date(), bump: Bool = true) -> LocalClip {
        if let i = items.firstIndex(where: { $0.same(kind: kind, text: text, data: data, serverID: serverID) }) {
            let c = items[i]
            if c.data == nil, let data { c.data = data }
            if c.serverID == nil { c.serverID = serverID }
            c.synced = c.synced || synced
            if bump {
                c.time = time
                c.from = from
                items.remove(at: i)
                items.insert(c, at: 0)
            }
            onChange?()
            return c
        }
        let c = LocalClip(id: nextID, kind: kind, text: text, data: data, mime: mime, size: size, from: from, time: time,
                          serverID: serverID, synced: synced)
        nextID += 1
        items.insert(c, at: 0)
        trim()
        onChange?()
        return c
    }

    @discardableResult
    func add(_ p: PasteContent, from: String, synced: Bool) -> LocalClip {
        add(kind: p.kind, text: p.text, data: p.data, mime: p.mime, size: p.data?.count ?? p.text?.utf8.count ?? 0,
            from: from, synced: synced)
    }

    func clip(_ id: Int) -> LocalClip? { items.first { $0.id == id } }

    /// Isi dari HistoryStore saat aplikasi dibuka
    func load(_ clips: [LocalClip], nextID n: Int) {
        items = clips
        nextID = max(n, (clips.map(\.id).max() ?? 0) + 1)
        trim()
        onChange?()
    }

    /// Clip yang disalin lagi naik ke paling atas (seperti Clipy)
    func bump(_ id: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let c = items.remove(at: i)
        c.time = Date()
        items.insert(c, at: 0)
        onChange?()
    }

    /// Keluarkan satu clip (untuk "Urungkan hapus": clip + posisinya dikembalikan lewat restore)
    func take(_ id: Int) -> (clip: LocalClip, index: Int)? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let c = items.remove(at: i)
        onChange?()
        return (c, i)
    }

    func restore(_ c: LocalClip, at index: Int) {
        guard !items.contains(where: { $0.id == c.id }) else { return }
        items.insert(c, at: min(index, items.count))
        trim()
        onChange?()
    }

    func remove(_ ids: Set<Int>) {
        items.removeAll { ids.contains($0.id) }
        onChange?()
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    /// Status clip berubah (mis. sudah terkirim)
    func changed() { onChange?() }

    private func trim() {
        if items.count > limit { items.removeLast(items.count - limit) }
        while items.count > 1, items.reduce(0, { $0 + ($1.data?.count ?? 0) }) > maxImageBytes { items.removeLast() }
    }
}

/// Riwayat Mac di disk (seperti CopyClip): tetap ada setelah PasteLAN / Mac di-restart. Folder
/// ~/Library/Application Support/PasteLAN/History (0700): history.json + satu file per gambar (0600).
/// Id item server tidak disimpan (berubah saat server restart); gambar dari server yang belum diambil tidak disimpan.
final class HistoryStore {
    private struct Saved: Codable {
        let nextID: Int
        let items: [Item]
    }
    private struct Item: Codable {
        let id: Int
        let kind: String
        let text: String?
        let mime: String?
        let size: Int
        let from: String
        let time: Date
        let synced: Bool
    }

    let dir: URL
    private var work: DispatchWorkItem?

    init(dir: URL) { self.dir = dir }

    private var jsonURL: URL { dir.appendingPathComponent("history.json") }
    private func imageURL(_ id: Int) -> URL { dir.appendingPathComponent("img-\(id)") }

    /// Simpan sebentar kemudian (perubahan beruntun → satu kali tulis)
    func saveSoon(_ h: History) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self, weak h] in
            if let self, let h { self.save(h) }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func save(_ h: History) {
        work?.cancel()
        work = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = Set<String>(["history.json"])
        var items: [Item] = []
        for c in h.items {
            if c.kind == "image" {
                guard let data = c.data else { continue } // gambar di server yang belum diambil
                let url = imageURL(c.id)
                keep.insert(url.lastPathComponent)
                if !fm.fileExists(atPath: url.path) { // isi clip tidak pernah berubah → cukup ditulis sekali
                    guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            items.append(Item(id: c.id, kind: c.kind, text: c.text, mime: c.mime, size: c.size, from: c.from,
                              time: c.time, synced: c.synced))
        }
        if let data = try? JSONEncoder().encode(Saved(nextID: h.nextID, items: items)) {
            try? data.write(to: jsonURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
        }
        // gambar yang sudah tidak ada di riwayat (dihapus / terbuang batas) ikut dihapus dari disk
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Isi riwayat yang tersimpan (terbaru di depan); gambar yang filenya hilang dilewati
    func load(into h: History) {
        guard let data = try? Data(contentsOf: jsonURL), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        var clips: [LocalClip] = []
        for it in s.items {
            var img: Data?
            if it.kind == "image" {
                img = try? Data(contentsOf: imageURL(it.id))
                if img == nil { continue }
            }
            clips.append(LocalClip(id: it.id, kind: it.kind, text: it.text, data: img, mime: it.mime, size: it.size,
                                   from: it.from, time: it.time, serverID: nil, synced: it.synced))
        }
        h.load(clips, nextID: s.nextID)
    }

    /// Penyimpanan dimatikan / uninstall: hapus semua file riwayat
    func wipe() {
        work?.cancel()
        work = nil
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Keychain (token perangkat; tidak pernah ditulis ke file pengaturan)

enum Keychain {
    static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "id.local.pastelan",
                                      kSecAttrAccount as String: "server-token"]

    static var token: String? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var q = base
            q[kSecValueData as String] = Data(newValue.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

// MARK: - Server PasteLAN (klien HTTP, hanya Foundation)

/// Satu item clipboard di server (isi gambar diambil terpisah lewat /api/image/<id>)
struct Clip: Decodable {
    let id: Int
    let kind: String   // "text" / "image"
    let text: String?
    let mime: String?
    let size: Int
    let from: String   // nama perangkat pengirim
    let device: String // id perangkat pengirim
    let time: Double?  // ms sejak epoch

    var date: Date { time.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date() }
}

/// Klien server PasteLAN: login dengan password → token Bearer, long-poll item baru, kirim teks / gambar.
/// Semua callback dipanggil di main thread.
final class PasteServer {
    enum State: Equatable { case loggedOut, connecting, connected, offline(String) }

    private(set) var base: URL?
    var token: String?                  // disimpan pemanggil di Keychain
    private(set) var me = ""            // id perangkat ini di server
    private(set) var state = State.loggedOut
    private(set) var items: [Clip] = [] // riwayat dari server, terlama di depan
    private(set) var running = false
    var onIncoming: ((Clip) -> Void)?   // item baru dari perangkat lain (langsung ditempel ke clipboard)
    var onSeen: ((Clip) -> Void)?       // item yang sudah ada di server saat (baru) tersambung → hanya masuk riwayat
    var onChange: (() -> Void)?         // status / riwayat berubah
    var onUnauthorized: (() -> Void)?   // token dicabut / tidak berlaku lagi

    private let http: URLSession
    private var session = ""   // id session server: berubah saat server restart / riwayat dihapus
    private var after = 0
    private var rev = -1       // penanda penghapusan item di server (-1 = belum tahu)
    private var primed = false // item yang sudah ada sebelum tersambung tidak ditempel ke clipboard
    private var gen = 0        // naik setiap start/stop → jawaban polling lama diabaikan
    private var retry: TimeInterval = 2

    init() {
        let c = URLSessionConfiguration.ephemeral // tanpa cookie / cache di disk; login memakai token Bearer
        c.timeoutIntervalForRequest = 40 // long-poll ditahan server ±25 detik
        c.httpShouldSetCookies = false
        http = URLSession(configuration: c)
    }

    /// "pastelan.example.com" → https://pastelan.example.com. HTTP hanya untuk localhost (uji coba).
    static func normalize(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if !t.contains("://") { t = "https://" + t }
        guard let u = URL(string: t), let host = u.host, !host.isEmpty, u.query == nil else { return nil }
        if u.scheme == "https" { return u }
        if u.scheme == "http", ["localhost", "127.0.0.1"].contains(host) { return u }
        return nil
    }

    func configure(base: URL?, token: String?) {
        self.base = base
        self.token = token
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, type: String? = nil) -> URLRequest? {
        guard let base, let url = URL(string: base.absoluteString + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "X-PasteLAN") // wajib di semua /api/ (perlindungan CSRF di server)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let type { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }

    /// done(status, isi, error jaringan) di main thread; status 0 = gagal jaringan
    private func send(_ r: URLRequest?, _ done: @escaping (Int, Data, String?) -> Void) {
        guard let r else { return done(0, Data(), "Alamat server tidak valid") }
        http.dataTask(with: r) { data, res, err in
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(status, data ?? Data(), err?.localizedDescription) }
        }.resume()
    }

    static func errorText(_ data: Data, _ status: Int, _ err: String?) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = j["error"] as? String { return e }
        return err ?? "HTTP \(status)"
    }

    /// Login dengan password → token baru untuk perangkat ini. done(token, nil) atau (nil, pesan error).
    func login(base: URL, password: String, name: String, _ done: @escaping (String?, String?) -> Void) {
        stop()
        self.base = base
        token = nil
        let body = try? JSONSerialization.data(withJSONObject: ["password": password, "name": name, "client": "mac"])
        send(request("POST", "/api/login", body: body, type: "application/json")) { status, data, err in
            guard status == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["token"] as? String else { return done(nil, PasteServer.errorText(data, status, err)) }
            self.token = t
            done(t, nil)
        }
    }

    /// Link setup / QR (https://server/#pair=<kode>) → alamat server + kode sekali pakai. nil kalau bukan link setup.
    static func setupLink(_ s: String) -> (base: URL, code: String)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: "#pair=") else { return nil }
        let code = String(t[r.upperBound...])
        var host = String(t[..<r.lowerBound])
        while host.hasSuffix("/") { host.removeLast() }
        guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let base = normalize(host) else { return nil }
        return (base, code)
    }

    /// Masuk dengan kode dari link setup (tanpa password) → token baru untuk perangkat ini
    func claim(base: URL, code: String, name: String, _ done: @escaping (String?, String?) -> Void) {
        stop()
        self.base = base
        token = nil
        let body = try? JSONSerialization.data(withJSONObject: ["code": code, "name": name, "client": "mac"])
        send(request("POST", "/api/pair/claim", body: body, type: "application/json")) { status, data, err in
            guard status == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["token"] as? String else { return done(nil, PasteServer.errorText(data, status, err)) }
            self.token = t
            done(t, nil)
        }
    }

    /// Cabut token Mac ini di server (perangkat hilang dari daftar), lalu lupakan token
    func logout(_ done: @escaping () -> Void) {
        let r = request("POST", "/api/logout")
        reset()
        send(r) { _, _, _ in done() }
    }

    private func reset() {
        stop()
        token = nil
        items = []
        session = ""
        after = 0
        rev = -1
        state = .loggedOut
        onChange?()
    }

    private func unauthorized() {
        guard token != nil else { return }
        reset()
        onUnauthorized?()
    }

    // MARK: menerima (long-poll)

    func start() {
        stop()
        guard base != nil, token != nil else { return reset() }
        running = true
        primed = false
        state = .connecting
        onChange?()
        poll(gen)
    }

    func stop() {
        gen += 1
        running = false
    }

    private func poll(_ g: Int) {
        guard g == gen else { return }
        let s = session.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        send(request("GET", "/api/items?after=\(after)&s=\(s)&r=\(rev)&wait=1")) { status, data, err in
            guard g == self.gen else { return }
            switch status {
            case 200:
                self.receive(data)
                self.retry = 2
                self.poll(g)
            case 401:
                self.unauthorized()
            default: // server mati / internet putus → coba lagi dengan jeda makin panjang (maks 30 detik)
                self.state = .offline(PasteServer.errorText(data, status, err))
                self.onChange?()
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retry) { self.poll(g) }
                self.retry = min(self.retry * 2, 30)
            }
        }
    }

    private func receive(_ data: Data) {
        // ids / rev: server ≥ 1.2.0 (item yang dihapus / kedaluwarsa ikut hilang dari riwayat Mac)
        struct Reply: Decodable { let session: String; let you: String; let items: [Clip]; let ids: [Int]?; let rev: Int? }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        me = r.you
        if r.session != session {
            session = r.session
            items = []
            after = 0
        }
        for c in r.items where c.id > after {
            items.append(c)
            after = c.id
            if !primed { onSeen?(c) } else if c.device != me { onIncoming?(c) }
        }
        if let ids = r.ids {
            let keep = Set(ids)
            items.removeAll { !keep.contains($0.id) }
        }
        rev = r.rev ?? -1
        primed = true
        if items.count > 20 { items.removeFirst(items.count - 20) }
        state = .connected
        onChange?()
    }

    // MARK: mengirim

    /// done(id item di server) setelah terkirim, atau done(nil) kalau gagal
    func sendText(_ s: String, _ done: ((Int?) -> Void)? = nil) { post("/api/text", Data(s.utf8), "text/plain; charset=utf-8", done) }
    func sendImage(_ d: Data, _ done: ((Int?) -> Void)? = nil) { post("/api/image", d, "application/octet-stream", done) } // jenis gambar dicek server dari isinya

    private func post(_ path: String, _ body: Data, _ type: String, _ done: ((Int?) -> Void)?) {
        send(request("POST", path, body: body, type: type)) { status, data, _ in
            if status == 401 { self.unauthorized() }
            let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            done?(status == 200 ? (j?["id"] as? NSNumber)?.intValue : nil)
        }
    }

    /// Link QR sekali pakai (5 menit) untuk menambah perangkat tanpa password: https://server/#pair=<kode>
    func pairLink(_ done: @escaping (URL?, Date?, String?) -> Void) {
        send(request("POST", "/api/pair")) { status, data, err in
            if status == 401 { self.unauthorized() }
            // server lama (< 1.1.0) belum punya /api/pair: v1.0.0 menjawab 405, versi baru 404
            if status == 404 || status == 405 {
                let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "terbaru" // tanpa Updater: bagian ini hanya Foundation
                return done(nil, nil, "Server PasteLAN di VPS masih versi lama dan belum mendukung QR (HTTP \(status)). " +
                    "Perbarui pastelan-server ke versi \(v) atau lebih baru (README server, " +
                    "bagian \"Memperbarui server\"), atau tambah HP dengan password dulu.")
            }
            guard status == 200, let base = self.base,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = j["code"] as? String, let exp = (j["expires"] as? NSNumber)?.doubleValue,
                  let url = URL(string: base.absoluteString + "/#pair=" + code)
            else { return done(nil, nil, PasteServer.errorText(data, status, err)) }
            done(url, Date(timeIntervalSince1970: exp / 1000), nil)
        }
    }

    func image(_ id: Int, _ done: @escaping (Data?) -> Void) {
        send(request("GET", "/api/image/\(id)")) { status, data, _ in done(status == 200 ? data : nil) }
    }

    func clearHistory() {
        send(request("DELETE", "/api/items")) { status, _, _ in
            if status == 401 { self.unauthorized() }
        }
    }
}

// MARK: - IP lokal

/// Interface yang bukan jaringan lokal (VPN, AirDrop, loopback, tunnel)
let skippedInterfaces = ["utun", "ipsec", "awdl", "llw", "lo", "gif", "stf"]

/// Subnet IPv4 interface lokal Mac (host byte order) → HP di LAN ber-IP non-pribadi tetap dikenali sebagai lokal
func localSubnets() -> [(net: UInt32, mask: UInt32)] {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    func ipv4(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }
    var out: [(net: UInt32, mask: UInt32)] = []
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = p.pointee.ifa_flags
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = p.pointee.ifa_netmask,
              flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: p.pointee.ifa_name)
        if skippedInterfaces.contains(where: { name.hasPrefix($0) }) { continue }
        let mask = ipv4(nm)
        if mask != 0 { out.append((ipv4(sa) & mask, mask)) }
    }
    return out
}

/// Alamat IPv4 Mac di jaringan lokal. Utamakan Wi-Fi / Ethernet (en*), lalu Internet Sharing (bridge*);
/// VPN (utun, ipsec), AirDrop (awdl, llw), loopback & link-local (169.254.x.x) diabaikan.
func localIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var found: [(rank: Int, ip: String)] = []
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = p.pointee.ifa_flags
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: p.pointee.ifa_name)
        if skippedInterfaces.contains(where: { name.hasPrefix($0) }) { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        if ip.hasPrefix("169.254.") { continue }
        let isPrivate = ip.hasPrefix("192.168.") || ip.hasPrefix("10.")
            || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
        var rank = name.hasPrefix("en") ? 0 : name.hasPrefix("bridge") ? 2 : 4
        if !isPrivate { rank += 1 }
        found.append((rank, ip))
    }
    return found.min { $0.rank < $1.rank }?.ip
}

// MARK: - Wi-Fi lokal: riwayat clipboard (hanya di memori, tidak pernah ditulis ke disk)

struct LANClip {
    let id: Int
    let kind: String     // "text" / "image"
    let from: String     // "mac" / "phone"
    let text: String?
    let data: Data?      // isi gambar
    let mime: String?
    let time: Date

    var size: Int { data?.count ?? text?.utf8.count ?? 0 }

    /// Untuk JSON di halaman HP (isi gambar diambil terpisah lewat /api/image/<id>)
    var info: [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind, "from": from, "time": Int(time.timeIntervalSince1970 * 1000), "size": size]
        if let text { d["text"] = text }
        if let mime { d["mime"] = mime }
        return d
    }

    /// Cuplikan satu baris untuk daftar riwayat di menu
    var title: String { clipTitle(kind: kind, text: text, mime: mime, size: size) }
    /// Keterangan pengirim (tooltip di menu)
    var source: String { from == "mac" ? "Dari Mac ini" : "Dari HP" }
}

final class LANStore {
    private(set) var items: [LANClip] = [] // terlama di depan, terbaru di belakang
    private(set) var session = randomHex(8) // berubah saat riwayat dihapus → HP mengosongkan daftarnya
    private var nextID = 1
    let maxItems = 20
    let maxImageBytes = 150 * 1024 * 1024
    var onAdd: ((LANClip) -> Void)?

    @discardableResult
    func add(kind: String, from: String, text: String? = nil, data: Data? = nil, mime: String? = nil) -> LANClip {
        // copy isi yang sama dua kali berturut-turut → tidak perlu item baru
        if let last = items.last, last.from == from, last.kind == kind, last.text == text, last.data == data { return last }
        let c = LANClip(id: nextID, kind: kind, from: from, text: text, data: data, mime: mime, time: Date())
        nextID += 1
        items.append(c)
        while items.count > maxItems { items.removeFirst() }
        while items.count > 1, items.reduce(0, { $0 + ($1.data?.count ?? 0) }) > maxImageBytes { items.removeFirst() }
        onAdd?(c)
        return c
    }

    func after(_ id: Int) -> [LANClip] { items.filter { $0.id > id } }
    func clip(_ id: Int) -> LANClip? { items.first { $0.id == id } }

    func clear() {
        items.removeAll()
        session = randomHex(8)
    }
}

// MARK: - Wi-Fi lokal: server HTTP mini (Network.framework, tanpa dependensi)

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // nama header huruf kecil
    let body: Data
    let auth: String // id request yang lolos cek kunci (AAD untuk isi terenkripsi), "" untuk halaman HTML
}

/// Hasil cek awal request, begitu header lengkap (sebelum body dibaca)
enum Gate {
    case allow(maxBody: Int, auth: String)
    case reject(status: Int, json: [String: Any])
}

final class HTTPConnection {
    private let conn: NWConnection
    private let maxBody: Int
    private var buffer = Data()
    private var parsed = false
    private var headerOK = false // header lengkap & lolos cek kunci/batas body
    private var gated: (limit: Int, auth: String)? // hasil gate (cek hanya sekali; id request hanya berlaku sekali)
    private var responded = false
    private(set) var closed = false
    let host: String // IP pengirim (tanpa port), untuk membatasi koneksi per perangkat
    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    var onClose: (() -> Void)?
    /// Dipanggil begitu header lengkap, SEBELUM body dibaca: izinkan (dengan batas body) atau tolak.
    /// Supaya perangkat tanpa kunci tidak bisa memenuhi memori dengan body besar.
    var gate: (_ method: String, _ path: String, _ headers: [String: String]) -> Gate = { _, _, _ in
        .reject(status: 403, json: ["error": "key"])
    }

    static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          411: "Length Required", 413: "Payload Too Large", 415: "Unsupported Media Type",
                          431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]

    init(_ c: NWConnection, maxBody: Int) {
        conn = c
        self.maxBody = maxBody
        host = HTTPServer.peerHost(c.endpoint)
    }

    /// Masih menunggu jawaban (mis. long-poll yang sedang ditahan)
    var isWaiting: Bool { !closed && !responded }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
        // klien yang tidak kunjung mengirim request lengkap diputus
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if let self, !self.parsed { self.cancel() }
        }
        // header saja harus lengkap jauh lebih cepat → slot koneksi tidak bisa ditahan klien yang diam
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, !self.headerOK { self.cancel() }
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if self.parse() { return }
            if isComplete || error != nil { return self.cancel() }
            self.receive()
        }
    }

    /// true kalau request sudah lengkap (atau sudah dijawab dengan error)
    private func parse() -> Bool {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 32 * 1024 { respond(431, text: "Header terlalu besar"); return true }
            return false
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { respond(400, text: "Bad request"); return true }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        // browser selalu mengirim Content-Length untuk fetch() dengan body string / File
        if headers["transfer-encoding"] != nil { respond(411, text: "Content-Length wajib"); return true }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { respond(400, text: "Content-Length tidak valid"); return true }
        let method = String(first[0]), target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let path = comps?.path ?? String(target.split(separator: "?").first ?? "/")
        // kunci & batas body dicek sebelum body ditunggu / disimpan di memori
        if gated == nil {
            switch gate(method, path, headers) {
            case let .reject(status, obj):
                respond(status, type: "application/json; charset=utf-8", body: json(obj)); return true
            case let .allow(maxBody: allowed, auth: auth):
                gated = (min(allowed, maxBody), auth)
            }
        }
        guard let g = gated else { return true }
        guard length <= g.limit else { respond(413, text: "Terlalu besar (maks \(byteString(g.limit)))"); return true }
        headerOK = true
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return false }

        let body = buffer.subdata(in: bodyStart..<bodyStart + length)
        parsed = true
        buffer = Data()
        onRequest?(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body, auth: g.auth), self)
        return true
    }

    func respond(_ status: Int, type: String = "text/plain; charset=utf-8", body: Data = Data(),
                 headers extra: [String: String] = [:]) {
        guard !closed, !responded else { return }
        responded = true
        parsed = true
        var head = "HTTP/1.1 \(status) \(HTTPConnection.reasons[status] ?? "OK")\r\n"
        var h = ["Content-Type": type, "Content-Length": "\(body.count)", "Connection": "close",
                 "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"]
        for (k, v) in extra { h[k] = v }
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    func respond(_ status: Int, text: String) { respond(status, body: Data(text.utf8)) }

    func respondJSON(_ obj: Any, status: Int = 200) {
        respond(status, type: "application/json; charset=utf-8", body: json(obj))
    }

    func cancel() { conn.cancel() }

    private func finish() {
        guard !closed else { return }
        closed = true
        let done = onClose
        onClose = nil
        onRequest = nil
        done?()
    }
}

final class HTTPServer {
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: HTTPConnection] = [:]
    private(set) var port: UInt16?
    private(set) var failed = false
    /// Koneksi masuk terakhir (diterima / ditolak) → ditampilkan di menu untuk cek apakah HP sampai ke Mac
    private(set) var lastPeer: (host: String, time: Date, note: String)?
    var handler: ((HTTPRequest, HTTPConnection) -> Void)?
    var gate: (_ method: String, _ path: String, _ headers: [String: String]) -> Gate = { _, _, _ in
        .reject(status: 403, json: ["error": "key"])
    }
    var onChange: (() -> Void)?

    let maxBody = 30 * 1024 * 1024
    let maxConnections = 64
    let maxPerHost = 12 // satu halaman HP butuh 1 long-poll + beberapa request kirim / gambar (browser: maks 6 paralel)

    var running: Bool { port != nil }

    /// Buka port `first`; kalau sibuk dipakai aplikasi lain, coba port berikutnya
    func start(from first: UInt16, tries: Int = 12) {
        stop()
        failed = false
        lastPeer = nil
        listen(first, remaining: tries)
    }

    private func listen(_ p: UInt16, remaining: Int) {
        guard remaining > 0, let nwPort = NWEndpoint.Port(rawValue: p) else {
            failed = true
            onChange?()
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: nwPort) else { return listen(p &+ 1, remaining: remaining - 1) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                self.port = p
                self.onChange?()
            case .failed:
                l.cancel()
                self.listener = nil
                self.port = nil
                self.listen(p &+ 1, remaining: remaining - 1)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for c in conns.values { c.cancel() }
        conns.removeAll()
    }

    private func accept(_ nc: NWConnection) {
        // hanya perangkat di jaringan lokal (bukan VPN / IP publik), dan satu perangkat tidak boleh memborong slot
        let peer = HTTPServer.peerHost(nc.endpoint)
        guard HTTPServer.isLocalPeer(nc.endpoint) else {
            lastPeer = (peer, Date(), "ditolak: bukan alamat lokal")
            return refuse(nc, 403, "PasteLAN hanya melayani perangkat di jaringan lokal yang sama dengan Mac. " +
                          "Alamat perangkat ini (\(peer)) tidak dikenali sebagai alamat lokal.")
        }
        guard conns.count < maxConnections else {
            lastPeer = (peer, Date(), "ditolak: server penuh")
            return refuse(nc, 503, "PasteLAN sedang sibuk, coba lagi sebentar.")
        }
        let c = HTTPConnection(nc, maxBody: maxBody)
        guard conns.values.filter({ $0.host == c.host }).count < maxPerHost else {
            lastPeer = (peer, Date(), "ditolak: terlalu banyak koneksi")
            return refuse(nc, 503, "Terlalu banyak koneksi dari perangkat ini, coba lagi sebentar.")
        }
        lastPeer = (peer, Date(), "diterima")
        let key = ObjectIdentifier(c)
        conns[key] = c
        c.gate = { [weak self] m, p, h in self?.gate(m, p, h) ?? .reject(status: 403, json: ["error": "key"]) }
        c.onRequest = { [weak self] req, c in self?.handler?(req, c) }
        c.onClose = { [weak self] in self?.conns[key] = nil }
        c.start()
    }

    /// Tolak dengan jawaban singkat, bukan memutus diam-diam: browser menampilkan alasannya
    /// (koneksi yang diputus tanpa jawaban dicoba ulang browser lalu gagal dengan ERR_TOO_MANY_RETRIES).
    /// Alasan juga dicatat di Console.app (cari "PasteLAN").
    private func refuse(_ nc: NWConnection, _ status: Int, _ msg: String) {
        NSLog("PasteLAN: tolak %@ (%d): %@", HTTPServer.peerHost(nc.endpoint), status, msg)
        let body = Data(msg.utf8)
        let head = "HTTP/1.1 \(status) \(HTTPConnection.reasons[status] ?? "Error")\r\nContent-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        nc.start(queue: .main)
        // baca dulu request-nya: menutup socket yang masih berisi data belum dibaca mengirim RST → jawaban bisa hilang
        nc.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            nc.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in nc.cancel() })
        }
        // klien yang tidak membaca jawaban tetap diputus
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { nc.cancel() }
    }

    /// IP pengirim tanpa port (untuk pesan & batas per perangkat)
    static func peerHost(_ ep: NWEndpoint) -> String {
        if case let .hostPort(h, _) = ep { return "\(h)" }
        return "\(ep)"
    }

    /// IP pribadi (10/8, 172.16/12, 192.168/16), satu subnet dengan Mac, link-local, loopback,
    /// atau IPv6 lokal (fe80::/10, fc00::/7)
    static func isLocalPeer(_ ep: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = ep else { return false }
        var v4: IPv4Address?
        switch host {
        case .ipv4(let a): v4 = a
        case .ipv6(let a):
            if let m = a.asIPv4 { v4 = m }
            else { return a.isLinkLocal || a.isLoopback || ([UInt8](a.rawValue).first ?? 0) & 0xfe == 0xfc }
        default: return false
        }
        guard let a = v4 else { return false }
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        if b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || a.isLinkLocal || a.isLoopback { return true }
        let ip = b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return localSubnets().contains { ip & $0.mask == $0.net }
    }
}

// MARK: - Wi-Fi lokal: server di Mac (HP di jaringan yang sama scan QR; isi dienkripsi dengan kunci di QR)

final class LANServer {
    let http = HTTPServer()
    let store = LANStore()
    let clipboard: Clipboard
    let d = UserDefaults.standard
    let macName = computerName()

    /// Kunci 256-bit di QR code (bagian #k= link, tidak pernah dikirim lewat jaringan).
    /// Semua isi API dienkripsi ChaCha20-Poly1305 dengan kunci ini → penyadap Wi-Fi tidak bisa membaca / memalsukan.
    var key = SymmetricKey(size: .bits256)
    var seen: [String: Int64] = [:] // id request (X-Auth) yang sudah dipakai → waktu (ms), anti replay
    var waiters: [(c: HTTPConnection, after: Int, auth: String)] = [] // long-poll yang sedang ditahan
    var onPhone: ((LANClip) -> Void)? // item dari HP (sudah masuk clipboard Mac)

    init(clipboard: Clipboard) {
        self.clipboard = clipboard
        d.register(defaults: ["port": 8787])
        if let k = d.string(forKey: "key").flatMap(fromB64url), k.count == 32 { key = SymmetricKey(data: k) } else { resetKey() }
        http.handler = { [weak self] r, c in self?.handle(r, c) }
        http.gate = { [weak self] m, p, h in self?.gate(m, p, h) ?? .reject(status: 403, json: ["error": "key"]) }
        store.onAdd = { [weak self] _ in self?.wakeWaiters() }
    }

    var running: Bool { http.running }
    var port: Int { d.integer(forKey: "port") }

    /// Link yang di-scan HP (nil kalau Mac tidak terhubung ke jaringan lokal / server belum jalan)
    var shareURL: String? {
        guard let port = http.port, let ip = localIPv4() else { return nil }
        return "http://\(ip):\(port)/#k=\(b64url(key.withUnsafeBytes { Data($0) }))"
    }

    /// Perkiraan jumlah HP yang sedang membuka halaman (tiap halaman menahan satu long-poll)
    var connectedCount: Int { waiters.filter { $0.c.isWaiting }.count }

    func start() {
        if !http.running { http.start(from: UInt16(clamping: port)) }
    }

    func stop() {
        waiters.removeAll()
        http.stop()
    }

    func add(_ c: PasteContent) {
        store.add(kind: c.kind, from: "mac", text: c.text, data: c.data, mime: c.mime)
    }

    func clearHistory() {
        store.clear()
        // HP yang sedang menunggu langsung diberi session baru → daftarnya dikosongkan
        wakeWaiters()
    }

    /// Kunci baru + server dimulai ulang (port & IP dibaca ulang) → semua link lama tidak berlaku
    func resetLink() {
        resetKey()
        let list = waiters
        waiters.removeAll()
        for w in list { w.c.respondJSON(["error": "key"], status: 403) }
        let wasRunning = http.running
        http.stop()
        if wasRunning { start() }
    }

    /// Item baru / riwayat dihapus → jawab semua HP yang sedang menunggu (long-poll)
    func wakeWaiters() {
        let list = waiters
        waiters.removeAll()
        for w in list { answerItems(w.c, after: w.after, auth: w.auth) }
    }

    func resetKey() {
        key = SymmetricKey(size: .bits256)
        d.set(b64url(key.withUnsafeBytes { Data($0) }), forKey: "key")
        seen.removeAll()
    }

    // MARK: HTTP

    /// Dicek begitu header request lengkap (sebelum body dibaca).
    /// Header X-Auth = "<waktu ms>.<base64url(nonce 12 B + tag 16 B)>": ChaChaPoly tanpa isi dengan
    /// AAD "PL1|req|<method>|<path>|<waktu>". Hanya pemegang kunci yang bisa membuatnya, dan tiap header
    /// hanya berlaku sekali (anti replay). Header ini juga menjadi id request untuk AAD isi & jawaban.
    func gate(_ method: String, _ path: String, _ headers: [String: String]) -> Gate {
        guard path.hasPrefix("/api/") else { return .allow(maxBody: 0, auth: "") } // halaman HTML: tanpa rahasia, tanpa body
        let deny = Gate.reject(status: 403, json: ["error": "key"])
        guard let h = headers["x-auth"], let dot = h.firstIndex(of: "."),
              let ts = Int64(h[..<dot]), ts > 0, ts < 1 << 50 else { return deny }
        let auth = String(h[h.index(after: dot)...])
        guard let raw = fromB64url(auth), raw.count == 28,
              let nonce = try? ChaChaPoly.Nonce(data: raw.prefix(12)),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: Data(), tag: raw.suffix(16)),
              (try? ChaChaPoly.open(box, using: key, authenticating: Data("PL1|req|\(method)|\(path)|\(ts)".utf8))) != nil
        else { return deny }
        // jam HP beda jauh → beri tahu waktu Mac (aman: hanya untuk pemegang kunci), halaman menyesuaikan lalu mengulang
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(now - ts) <= 300_000 else { return .reject(status: 409, json: ["error": "time", "now": now]) }
        seen = seen.filter { now - $0.value <= 600_000 }
        guard seen[auth] == nil else { return deny }
        seen[auth] = now
        switch (method, path) {
        case ("POST", "/api/text"): return .allow(maxBody: clipboard.maxText + 64, auth: auth) // + nonce & tag
        case ("POST", "/api/image"): return .allow(maxBody: clipboard.maxImage + 256, auth: auth) // + MIME, nonce & tag
        default: return .allow(maxBody: 0, auth: auth)
        }
    }

    /// Isi request dari HP: kotak ChaChaPoly (nonce + ciphertext + tag) dengan AAD "PL1|body|<id request>"
    func openBody(_ r: HTTPRequest) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: r.body) else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: Data("PL1|body|\(r.auth)".utf8))
    }

    /// Jawaban 200 selalu terenkripsi, terikat ke request-nya (AAD "PL1|resp|<id request>")
    func respondSealed(_ c: HTTPConnection, _ plain: Data, auth: String) {
        guard let box = try? ChaChaPoly.seal(plain, using: key, authenticating: Data("PL1|resp|\(auth)".utf8)) else {
            return c.respond(500, text: "Gagal mengenkripsi")
        }
        c.respond(200, type: "application/octet-stream", body: box.combined)
    }

    func handle(_ r: HTTPRequest, _ c: HTTPConnection) {
        // halaman tidak berisi rahasia (kunci ada di #k=, dibaca JS di HP); semua /api/ sudah lolos gate()
        if r.path == "/" || r.path == "/index.html" {
            return c.respond(200, type: "text/html; charset=utf-8", body: Data(Page.html.utf8))
        }
        guard r.path.hasPrefix("/api/"), !r.auth.isEmpty else { return c.respond(404, text: "Tidak ditemukan") }

        switch (r.method, r.path) {
        case ("GET", "/api/items"):
            // session beda (Mac baru dibuka / riwayat dihapus) → kirim ulang semua item
            let fresh = r.query["s"] != store.session
            let after = fresh ? 0 : Int(r.query["after"] ?? "") ?? 0
            if !fresh, r.query["wait"] == "1", store.after(after).isEmpty {
                waiters.append((c, after, r.auth))
                // tidak ada item baru dalam 25 detik → jawab kosong, halaman langsung bertanya lagi
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self, weak c] in
                    guard let self, let c, let i = self.waiters.firstIndex(where: { $0.c === c }) else { return }
                    self.waiters.remove(at: i)
                    self.answerItems(c, after: after, auth: r.auth)
                }
                return
            }
            answerItems(c, after: after, auth: r.auth)

        case ("POST", "/api/text"):
            guard let plain = openBody(r) else { return c.respondJSON(["error": "Gagal membuka isi terenkripsi"], status: 400) }
            guard let text = String(data: plain, encoding: .utf8), !text.isEmpty else {
                return c.respondJSON(["error": "Teks kosong"], status: 400)
            }
            clipboard.writeText(text)
            let clip = store.add(kind: "text", from: "phone", text: text)
            onPhone?(clip)
            respondSealed(c, json(["ok": true, "id": clip.id]), auth: r.auth)

        case ("POST", "/api/image"):
            // isi terenkripsi = "<mime>\n" + byte gambar (MIME ikut dienkripsi)
            guard let plain = openBody(r) else { return c.respondJSON(["error": "Gagal membuka isi terenkripsi"], status: 400) }
            guard let nl = plain.prefix(128).firstIndex(of: 0x0A) else { return c.respondJSON(["error": "Format tidak dikenal"], status: 400) }
            var mime = String(decoding: plain[plain.startIndex..<nl], as: UTF8.self).lowercased()
            if mime == "image/jpg" { mime = "image/jpeg" }
            let data = Data(plain[(nl + 1)...])
            guard !data.isEmpty, clipboard.writeImage(data, mime: mime) else {
                return c.respondJSON(["error": "Bukan gambar yang didukung"], status: 415)
            }
            // MIME dari HP ikut dikirim balik di daftar item → hanya format gambar biasa (bukan image/svg+xml dll.)
            let clip = store.add(kind: "image", from: "phone", data: data, mime: Clipboard.imageMimes.contains(mime) ? mime : "image/png")
            onPhone?(clip)
            respondSealed(c, json(["ok": true, "id": clip.id]), auth: r.auth)

        case ("GET", let p) where p.hasPrefix("/api/image/"):
            guard let id = Int(p.dropFirst("/api/image/".count)), let clip = store.clip(id), let data = clip.data else {
                return c.respond(404, text: "Gambar tidak ada lagi di riwayat")
            }
            // terenkripsi → halaman membukanya lalu menampilkan sebagai blob: (jenis gambar dari daftar item)
            respondSealed(c, data, auth: r.auth)

        default:
            c.respond(404, text: "Tidak ditemukan")
        }
    }

    func answerItems(_ c: HTTPConnection, after: Int, auth: String) {
        respondSealed(c, json(["session": store.session, "name": macName, "items": store.after(after).map { $0.info }]), auth: auth)
    }
}

// MARK: - Wi-Fi lokal: halaman web untuk HP (ditanam di aplikasi, tanpa file / CDN eksternal)

enum Page {
    static let html = #"""
    <!doctype html>
    <html lang="id">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#f5f5f7" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="PasteLAN">
    <meta name="referrer" content="no-referrer">
    <title>PasteLAN</title>
    <style>
    :root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#007aff;--ok:#34c759;--bad:#ff3b30}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--muted:#98989d;--line:#38383a;--accent:#0a84ff;--ok:#30d158;--bad:#ff453a}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
    header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:8px;padding:12px 16px;padding-top:calc(12px + env(safe-area-inset-top));background:var(--bg);border-bottom:1px solid var(--line)}
    header h1{font-size:18px;margin:0;flex:1}
    .dot{width:10px;height:10px;border-radius:50%;background:var(--muted);flex:none}
    .dot.on{background:var(--ok)}.dot.off{background:var(--bad)}
    #status{font-size:13px;color:var(--muted);text-align:right}
    main{max-width:640px;margin:0 auto;padding:16px;padding-bottom:calc(32px + env(safe-area-inset-bottom))}
    .card{background:var(--card);border-radius:14px;padding:12px;margin-bottom:12px;border:1px solid var(--line)}
    textarea{width:100%;min-height:96px;resize:vertical;border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit;background:transparent;color:inherit}
    .row{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}
    button,.btn{appearance:none;-webkit-appearance:none;border:0;border-radius:10px;padding:10px 14px;font:inherit;font-weight:600;background:var(--accent);color:#fff;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;justify-content:center}
    .ghost{background:transparent;color:var(--accent);border:1px solid var(--line)}
    button:disabled{opacity:.5}
    .grow{flex:1}
    .meta{display:flex;justify-content:space-between;gap:8px;font-size:12px;color:var(--muted);margin-bottom:6px}
    .txt{white-space:pre-wrap;word-break:break-word;max-height:9.5em;overflow:hidden}
    .txt.full{max-height:none}
    .item img{display:block;max-width:100%;max-height:360px;border-radius:8px;margin:0 auto;-webkit-touch-callout:default}
    .empty{text-align:center;color:var(--muted);padding:24px 8px}
    .hint{font-size:12px;color:var(--muted);margin-top:6px}
    h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:20px 4px 8px}
    #toast{position:fixed;left:50%;bottom:calc(24px + env(safe-area-inset-bottom));transform:translateX(-50%);background:rgba(0,0,0,.85);color:#fff;padding:8px 14px;border-radius:20px;font-size:14px;opacity:0;transition:opacity .2s;pointer-events:none;max-width:90%;text-align:center}
    #toast.show{opacity:1}
    .search{width:100%;margin:0 0 12px;border:1px solid var(--line);border-radius:10px;padding:10px;font:inherit;background:var(--card);color:inherit;-webkit-appearance:none;appearance:none}
    .item.hide,[hidden]{display:none!important}
    </style>
    </head>
    <body>
    <header><span id="dot" class="dot"></span><h1>PasteLAN</h1><span id="status">Menghubungkan…</span></header>
    <main>
      <div class="card">
        <textarea id="input" placeholder="Tempel teks di sini, lalu kirim ke Mac…"></textarea>
        <div class="row">
          <button id="send" class="grow">Kirim ke Mac</button>
          <button id="pick" class="ghost">Kirim gambar</button>
          <input id="file" type="file" accept="image/*" multiple hidden>
        </div>
        <div class="hint">Setelah terkirim, tekan ⌘V di Mac. Gambar juga bisa ditempel langsung di kotak teks.</div>
      </div>
      <h2>Clipboard</h2>
      <input id="search" class="search" type="search" placeholder="Cari clip…" autocomplete="off" aria-label="Cari clip">
      <div id="noMatch" class="empty" hidden></div>
      <div id="list"></div>
    </main>
    <div id="toast"></div>
    <script>
    (() => {
      // ---------- ChaCha20-Poly1305 (RFC 8439), sama dengan CryptoKit.ChaChaPoly ----------
      // HTTP lokal bukan "secure context" → crypto.subtle tidak ada, jadi ditulis sendiri.
      // Format kotak tersegel = nonce (12 B) + ciphertext + tag (16 B), sama dengan SealedBox.combined.
      const AEAD = (() => {
        // satu blok keystream (64 B) → out (Uint32Array 16); variabel lokal supaya cepat di JIT
        function block(k, counter, n, out) {
          const j0 = 0x61707865, j1 = 0x3320646e, j2 = 0x79622d32, j3 = 0x6b206574;
          let x0 = j0, x1 = j1, x2 = j2, x3 = j3, x4 = k[0], x5 = k[1], x6 = k[2], x7 = k[3];
          let x8 = k[4], x9 = k[5], x10 = k[6], x11 = k[7], x12 = counter, x13 = n[0], x14 = n[1], x15 = n[2], t;
          for (let i = 0; i < 10; i++) {
            x0 = x0 + x4 | 0; t = x12 ^ x0; x12 = t << 16 | t >>> 16; x8 = x8 + x12 | 0; t = x4 ^ x8; x4 = t << 12 | t >>> 20;
            x0 = x0 + x4 | 0; t = x12 ^ x0; x12 = t << 8 | t >>> 24; x8 = x8 + x12 | 0; t = x4 ^ x8; x4 = t << 7 | t >>> 25;
            x1 = x1 + x5 | 0; t = x13 ^ x1; x13 = t << 16 | t >>> 16; x9 = x9 + x13 | 0; t = x5 ^ x9; x5 = t << 12 | t >>> 20;
            x1 = x1 + x5 | 0; t = x13 ^ x1; x13 = t << 8 | t >>> 24; x9 = x9 + x13 | 0; t = x5 ^ x9; x5 = t << 7 | t >>> 25;
            x2 = x2 + x6 | 0; t = x14 ^ x2; x14 = t << 16 | t >>> 16; x10 = x10 + x14 | 0; t = x6 ^ x10; x6 = t << 12 | t >>> 20;
            x2 = x2 + x6 | 0; t = x14 ^ x2; x14 = t << 8 | t >>> 24; x10 = x10 + x14 | 0; t = x6 ^ x10; x6 = t << 7 | t >>> 25;
            x3 = x3 + x7 | 0; t = x15 ^ x3; x15 = t << 16 | t >>> 16; x11 = x11 + x15 | 0; t = x7 ^ x11; x7 = t << 12 | t >>> 20;
            x3 = x3 + x7 | 0; t = x15 ^ x3; x15 = t << 8 | t >>> 24; x11 = x11 + x15 | 0; t = x7 ^ x11; x7 = t << 7 | t >>> 25;
            x0 = x0 + x5 | 0; t = x15 ^ x0; x15 = t << 16 | t >>> 16; x10 = x10 + x15 | 0; t = x5 ^ x10; x5 = t << 12 | t >>> 20;
            x0 = x0 + x5 | 0; t = x15 ^ x0; x15 = t << 8 | t >>> 24; x10 = x10 + x15 | 0; t = x5 ^ x10; x5 = t << 7 | t >>> 25;
            x1 = x1 + x6 | 0; t = x12 ^ x1; x12 = t << 16 | t >>> 16; x11 = x11 + x12 | 0; t = x6 ^ x11; x6 = t << 12 | t >>> 20;
            x1 = x1 + x6 | 0; t = x12 ^ x1; x12 = t << 8 | t >>> 24; x11 = x11 + x12 | 0; t = x6 ^ x11; x6 = t << 7 | t >>> 25;
            x2 = x2 + x7 | 0; t = x13 ^ x2; x13 = t << 16 | t >>> 16; x8 = x8 + x13 | 0; t = x7 ^ x8; x7 = t << 12 | t >>> 20;
            x2 = x2 + x7 | 0; t = x13 ^ x2; x13 = t << 8 | t >>> 24; x8 = x8 + x13 | 0; t = x7 ^ x8; x7 = t << 7 | t >>> 25;
            x3 = x3 + x4 | 0; t = x14 ^ x3; x14 = t << 16 | t >>> 16; x9 = x9 + x14 | 0; t = x4 ^ x9; x4 = t << 12 | t >>> 20;
            x3 = x3 + x4 | 0; t = x14 ^ x3; x14 = t << 8 | t >>> 24; x9 = x9 + x14 | 0; t = x4 ^ x9; x4 = t << 7 | t >>> 25;
          }
          out[0] = x0 + j0; out[1] = x1 + j1; out[2] = x2 + j2; out[3] = x3 + j3;
          out[4] = x4 + k[0]; out[5] = x5 + k[1]; out[6] = x6 + k[2]; out[7] = x7 + k[3];
          out[8] = x8 + k[4]; out[9] = x9 + k[5]; out[10] = x10 + k[6]; out[11] = x11 + k[7];
          out[12] = x12 + counter; out[13] = x13 + n[0]; out[14] = x14 + n[1]; out[15] = x15 + n[2];
        }
        const words = (b, n) => { const w = new Uint32Array(n); for (let i = 0; i < n; i++) w[i] = b[4 * i] | b[4 * i + 1] << 8 | b[4 * i + 2] << 16 | b[4 * i + 3] << 24; return w; };
        // XOR dengan keystream mulai dari blok `counter`
        function chacha(key, nonce, counter, input) {
          const k = words(key, 8), n = words(nonce, 3), out = new Uint8Array(input.length);
          const ks = new Uint32Array(16), ks8 = new Uint8Array(ks.buffer); // little-endian di semua HP
          for (let off = 0; off < input.length; off += 64, counter++) {
            block(k, counter, n, ks);
            const end = Math.min(64, input.length - off);
            for (let i = 0; i < end; i++) out[off + i] = input[off + i] ^ ks8[i];
          }
          return out;
        }
        // Poly1305 dengan 10 limb 13-bit (Float64Array: semua hasil kali & jumlah < 2^53 → eksak)
        function limbs(b, o, hibit, h) {
          const t0 = b[o] | b[o + 1] << 8, t1 = b[o + 2] | b[o + 3] << 8, t2 = b[o + 4] | b[o + 5] << 8, t3 = b[o + 6] | b[o + 7] << 8;
          const t4 = b[o + 8] | b[o + 9] << 8, t5 = b[o + 10] | b[o + 11] << 8, t6 = b[o + 12] | b[o + 13] << 8, t7 = b[o + 14] | b[o + 15] << 8;
          h[0] += t0 & 0x1fff;
          h[1] += ((t0 >>> 13) | (t1 << 3)) & 0x1fff;
          h[2] += ((t1 >>> 10) | (t2 << 6)) & 0x1fff;
          h[3] += ((t2 >>> 7) | (t3 << 9)) & 0x1fff;
          h[4] += ((t3 >>> 4) | (t4 << 12)) & 0x1fff;
          h[5] += (t4 >>> 1) & 0x1fff;
          h[6] += ((t4 >>> 14) | (t5 << 2)) & 0x1fff;
          h[7] += ((t5 >>> 11) | (t6 << 5)) & 0x1fff;
          h[8] += ((t6 >>> 8) | (t7 << 8)) & 0x1fff;
          h[9] += (t7 >>> 5) | hibit;
        }
        // setelah ini semua limb < 2^13 (nilai < 2^130)
        function carry(h) {
          let c;
          do {
            c = 0;
            for (let i = 0; i < 10; i++) { const v = h[i] + c; c = Math.floor(v / 8192); h[i] = v - c * 8192; }
            h[0] += c * 5; // 2^130 ≡ 5 (mod p)
          } while (c);
        }
        // msg: panjangnya selalu kelipatan 16 (AEAD sudah di-pad)
        function poly1305(key, msg) {
          const rb = key.slice(0, 16);
          rb[3] &= 15; rb[7] &= 15; rb[11] &= 15; rb[15] &= 15; rb[4] &= 252; rb[8] &= 252; rb[12] &= 252;
          const r = new Float64Array(10); limbs(rb, 0, 0, r);
          const r0 = r[0], r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4], r5 = r[5], r6 = r[6], r7 = r[7], r8 = r[8], r9 = r[9];
          const s1 = 5 * r1, s2 = 5 * r2, s3 = 5 * r3, s4 = 5 * r4, s5 = 5 * r5, s6 = 5 * r6, s7 = 5 * r7, s8 = 5 * r8, s9 = 5 * r9; // 2^130 ≡ 5 (mod p)
          const h = new Float64Array(10);
          let h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0, h5 = 0, h6 = 0, h7 = 0, h8 = 0, h9 = 0, c;
          for (let o = 0; o < msg.length; o += 16) {
            const t0 = msg[o] | msg[o + 1] << 8, t1 = msg[o + 2] | msg[o + 3] << 8, t2 = msg[o + 4] | msg[o + 5] << 8, t3 = msg[o + 6] | msg[o + 7] << 8;
            const t4 = msg[o + 8] | msg[o + 9] << 8, t5 = msg[o + 10] | msg[o + 11] << 8, t6 = msg[o + 12] | msg[o + 13] << 8, t7 = msg[o + 14] | msg[o + 15] << 8;
            h0 += t0 & 0x1fff; h1 += ((t0 >>> 13) | (t1 << 3)) & 0x1fff; h2 += ((t1 >>> 10) | (t2 << 6)) & 0x1fff;
            h3 += ((t2 >>> 7) | (t3 << 9)) & 0x1fff; h4 += ((t3 >>> 4) | (t4 << 12)) & 0x1fff; h5 += (t4 >>> 1) & 0x1fff;
            h6 += ((t4 >>> 14) | (t5 << 2)) & 0x1fff; h7 += ((t5 >>> 11) | (t6 << 5)) & 0x1fff; h8 += ((t6 >>> 8) | (t7 << 8)) & 0x1fff;
            h9 += (t7 >>> 5) | 1 << 11; // + 2^128
            let d0 = h0 * r0 + h1 * s9 + h2 * s8 + h3 * s7 + h4 * s6 + h5 * s5 + h6 * s4 + h7 * s3 + h8 * s2 + h9 * s1;
            let d1 = h0 * r1 + h1 * r0 + h2 * s9 + h3 * s8 + h4 * s7 + h5 * s6 + h6 * s5 + h7 * s4 + h8 * s3 + h9 * s2;
            let d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s9 + h4 * s8 + h5 * s7 + h6 * s6 + h7 * s5 + h8 * s4 + h9 * s3;
            let d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s9 + h5 * s8 + h6 * s7 + h7 * s6 + h8 * s5 + h9 * s4;
            let d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0 + h5 * s9 + h6 * s8 + h7 * s7 + h8 * s6 + h9 * s5;
            let d5 = h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1 + h5 * r0 + h6 * s9 + h7 * s8 + h8 * s7 + h9 * s6;
            let d6 = h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2 + h5 * r1 + h6 * r0 + h7 * s9 + h8 * s8 + h9 * s7;
            let d7 = h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3 + h5 * r2 + h6 * r1 + h7 * r0 + h8 * s9 + h9 * s8;
            let d8 = h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4 + h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * s9;
            let d9 = h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5 + h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
            // carry ringan: cukup supaya limb tetap kecil untuk perkalian berikutnya
            c = Math.floor(d0 / 8192); h0 = d0 - c * 8192;
            d1 += c; c = Math.floor(d1 / 8192); h1 = d1 - c * 8192;
            d2 += c; c = Math.floor(d2 / 8192); h2 = d2 - c * 8192;
            d3 += c; c = Math.floor(d3 / 8192); h3 = d3 - c * 8192;
            d4 += c; c = Math.floor(d4 / 8192); h4 = d4 - c * 8192;
            d5 += c; c = Math.floor(d5 / 8192); h5 = d5 - c * 8192;
            d6 += c; c = Math.floor(d6 / 8192); h6 = d6 - c * 8192;
            d7 += c; c = Math.floor(d7 / 8192); h7 = d7 - c * 8192;
            d8 += c; c = Math.floor(d8 / 8192); h8 = d8 - c * 8192;
            d9 += c; c = Math.floor(d9 / 8192); h9 = d9 - c * 8192;
            h0 += c * 5;
          }
          h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4; h[5] = h5; h[6] = h6; h[7] = h7; h[8] = h8; h[9] = h9;
          carry(h);
          // h ≥ p (= 2^130 - 5)? → kurangi p
          const g = Float64Array.from(h); g[0] += 5;
          c = 0;
          for (let i = 0; i < 10; i++) { const v = g[i] + c; c = Math.floor(v / 8192); g[i] = v - c * 8192; }
          const f = c > 0 ? g : h; // h + 5 ≥ 2^130
          const w = [
            (f[0] | f[1] << 13), (f[1] >>> 3 | f[2] << 10), (f[2] >>> 6 | f[3] << 7), (f[3] >>> 9 | f[4] << 4),
            (f[4] >>> 12 | f[5] << 1 | f[6] << 14), (f[6] >>> 2 | f[7] << 11), (f[7] >>> 5 | f[8] << 8), (f[8] >>> 8 | f[9] << 5)
          ];
          const tag = new Uint8Array(16);
          c = 0;
          for (let i = 0; i < 8; i++) {
            const v = (w[i] & 0xffff) + (key[16 + 2 * i] | key[17 + 2 * i] << 8) + c;
            tag[2 * i] = v & 255; tag[2 * i + 1] = (v >>> 8) & 255; c = v >>> 16;
          }
          return tag;
        }
        function mac(key, nonce, aad, ct) {
          const pk = chacha(key, nonce, 0, new Uint8Array(32));
          const pad = n => (16 - n % 16) % 16;
          const m = new Uint8Array(aad.length + pad(aad.length) + ct.length + pad(ct.length) + 16);
          m.set(aad, 0); m.set(ct, aad.length + pad(aad.length));
          const dv = new DataView(m.buffer, m.length - 16);
          dv.setUint32(0, aad.length, true); dv.setUint32(8, ct.length, true); // < 4 GB
          return poly1305(pk, m);
        }
        const enc = s => new TextEncoder().encode(s);
        return {
          seal(key, plain, aad) {
            const nonce = crypto.getRandomValues(new Uint8Array(12));
            const ct = chacha(key, nonce, 1, plain);
            const out = new Uint8Array(12 + ct.length + 16);
            out.set(nonce); out.set(ct, 12); out.set(mac(key, nonce, enc(aad), ct), 12 + ct.length);
            return out;
          },
          // null kalau tag tidak cocok (kunci salah / data diubah)
          open(key, box, aad) {
            if (box.length < 28) return null;
            const nonce = box.subarray(0, 12), ct = box.subarray(12, box.length - 16), tag = box.subarray(box.length - 16);
            const t = mac(key, nonce, enc(aad), ct);
            let diff = 0;
            for (let i = 0; i < 16; i++) diff |= t[i] ^ tag[i];
            return diff ? null : chacha(key, nonce, 1, ct);
          }
        };
      })();

      // kunci dari #k= (fragment tidak pernah dikirim lewat jaringan); disimpan juga untuk ikon Layar Utama
      const b64d = s => { try { return Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)); } catch (e) { return null; } };
      const b64e = a => btoa(String.fromCharCode(...a)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      let keyText = new URLSearchParams(location.hash.slice(1)).get('k') || '';
      try { if (keyText) localStorage.setItem('pastelan-key', keyText); else keyText = localStorage.getItem('pastelan-key') || ''; } catch (e) {}
      const key = b64d(keyText);
      const $ = id => document.getElementById(id);
      const MAX_ITEMS = 20, MAX_BYTES = 30 * 1024 * 1024;
      let after = 0, session = '', stopped = false, ctrl = null, clockOffset = 0; // clockOffset = jam Mac − jam HP (ms)

      function toast(msg) {
        const t = $('toast');
        t.textContent = msg;
        t.classList.add('show');
        clearTimeout(toast.h);
        toast.h = setTimeout(() => t.classList.remove('show'), 2000);
      }
      function setStatus(state, text) { $('dot').className = 'dot ' + state; $('status').textContent = text; }
      const sleep = ms => new Promise(r => setTimeout(r, ms));

      function showEmpty() {
        if (!$('list').children.length) $('list').innerHTML = '<div class="empty">Belum ada apa-apa. Copy sesuatu di Mac (⌘C), atau kirim dari HP ini.</div>';
        filter();
      }
      // pencarian (isi teks; gambar cocok dengan "gambar")
      function filter() {
        const q = $('search').value.trim().toLowerCase();
        let shown = 0, total = 0;
        for (const c of $('list').children) {
          if (c.searchText == null) continue;
          total++;
          const hit = !q || c.searchText.includes(q);
          c.classList.toggle('hide', !hit);
          if (hit) shown++;
        }
        $('noMatch').hidden = !q || !total || shown > 0;
        $('noMatch').textContent = 'Tidak ada clip yang cocok dengan "' + $('search').value.trim() + '".';
      }
      $('search').addEventListener('input', filter);
      function expired() {
        stopped = true;
        setStatus('off', 'Link tidak berlaku');
        $('list').innerHTML = '<div class="card empty">Link ini sudah tidak berlaku. Klik ikon PasteLAN (penjepit kertas) di menu bar Mac → Tambah HP, lalu scan ulang QR code-nya.</div>';
      }

      // Semua request terenkripsi: X-Auth membuktikan pemegang kunci (sekali pakai), body & jawaban 200 berupa
      // kotak ChaCha20-Poly1305 yang terikat ke X-Auth itu. Penyadap Wi-Fi hanya melihat ukuran & waktu.
      async function api(path, { method = 'GET', body = null, signal, raw = false } = {}, retry = true) {
        const ts = Date.now() + clockOffset;
        const auth = b64e(AEAD.seal(key, new Uint8Array(0), `PL1|req|${method}|${path.split('?')[0]}|${ts}`));
        const opts = { method, signal, headers: { 'X-Auth': ts + '.' + auth } };
        if (body) { opts.body = AEAD.seal(key, body, 'PL1|body|' + auth); opts.headers['Content-Type'] = 'application/octet-stream'; }
        const r = await fetch(path, opts);
        if (r.status === 403) { expired(); throw new Error('403'); }
        if (!r.ok) {
          const j = await r.json().catch(() => ({}));
          // jam HP beda jauh dengan Mac → sesuaikan, ulangi sekali
          if (r.status === 409 && j.now && retry) { clockOffset = j.now - Date.now(); return api(path, { method, body, signal, raw }, false); }
          throw new Error(j.error || ('HTTP ' + r.status));
        }
        const plain = AEAD.open(key, new Uint8Array(await r.arrayBuffer()), 'PL1|resp|' + auth);
        if (!plain) throw new Error('jawaban rusak');
        return raw ? plain : JSON.parse(new TextDecoder().decode(plain));
      }
      function clearList() {
        for (const c of $('list').children) if (c.blobURL) URL.revokeObjectURL(c.blobURL);
        $('list').textContent = '';
      }

      // ---------- menerima dari Mac (long-poll) ----------
      async function poll() {
        while (!stopped) {
          ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), 35000);
          try {
            const j = await api(`/api/items?after=${after}&s=${encodeURIComponent(session)}&wait=1`, { signal: ctrl.signal });
            if (j.session !== session) { session = j.session; after = 0; clearList(); }
            setStatus('on', 'Terhubung ke ' + j.name);
            for (const it of j.items) { add(it); after = Math.max(after, it.id); }
            showEmpty();
          } catch (e) {
            if (stopped) return;
            if (e.name !== 'AbortError') { setStatus('off', 'Terputus, mencoba lagi…'); await sleep(2000); }
          } finally { clearTimeout(timer); }
        }
      }
      // HP baru dibuka / pindah tab → jangan tunggu request lama yang mungkin sudah mati
      document.addEventListener('visibilitychange', () => { if (!document.hidden && ctrl) ctrl.abort(); });

      function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
      }
      function button(label, cls, onclick) {
        const b = el('button', cls, label);
        b.onclick = () => onclick(b);
        return b;
      }

      function add(it) {
        const list = $('list');
        const empty = list.querySelector('.empty');
        if (empty) empty.remove();
        const card = el('div', 'card item');
        card.searchText = (it.kind === 'text' ? it.text : 'gambar image ' + (it.mime || '')).toLowerCase();
        const meta = el('div', 'meta');
        const time = new Date(it.time).toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' });
        meta.append(el('span', '', it.from === 'mac' ? '💻 Dari Mac' : '📱 Dari HP'), el('span', '', time));
        card.append(meta);
        const row = el('div', 'row');
        if (it.kind === 'text') {
          const t = el('div', 'txt', it.text);
          card.append(t);
          row.append(button('Salin', 'grow', () => copyText(it.text)));
          if (it.text.length > 300 || it.text.split('\n').length > 6) {
            row.append(button('Selengkapnya', 'ghost', b => {
              t.classList.toggle('full');
              b.textContent = t.classList.contains('full') ? 'Ringkas' : 'Selengkapnya';
            }));
          }
        } else {
          const img = el('img');
          img.alt = 'Gambar';
          card.append(img);
          const a = el('a', 'btn grow', 'Simpan / buka');
          // gambar terenkripsi → dibuka di HP lalu ditampilkan sebagai blob:
          api(`/api/image/${it.id}?s=${encodeURIComponent(session)}`, { raw: true }).then(bytes => {
            card.blobURL = img.src = a.href = URL.createObjectURL(new Blob([bytes], { type: it.mime || 'image/png' }));
          }).catch(() => { img.alt = 'Gambar gagal dimuat'; });
          a.download = `pastelan-${it.id}.${(it.mime || 'image/png').split('/')[1].replace('jpeg', 'jpg')}`;
          a.target = '_blank';
          row.append(a);
        }
        card.append(row);
        if (it.kind !== 'text') card.append(el('div', 'hint', 'Tekan lama gambar untuk menyalin atau menyimpan.'));
        list.prepend(card);
        while (list.children.length > MAX_ITEMS) {
          if (list.lastChild.blobURL) URL.revokeObjectURL(list.lastChild.blobURL);
          list.lastChild.remove();
        }
        filter();
      }

      // HTTP lokal bukan "secure context" → navigator.clipboard sering tidak ada, pakai cara lama
      async function copyText(text) {
        try {
          if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); return toast('Tersalin ✓'); }
        } catch (e) {}
        const ta = el('textarea');
        ta.value = text;
        ta.readOnly = true;
        ta.contentEditable = 'true';
        Object.assign(ta.style, { position: 'fixed', top: '0', left: '0', opacity: '0', fontSize: '16px' });
        document.body.append(ta);
        const range = document.createRange();
        range.selectNodeContents(ta);
        const sel = getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        ta.select();
        ta.setSelectionRange(0, text.length);
        let ok = false;
        try { ok = document.execCommand('copy'); } catch (e) {}
        ta.remove();
        sel.removeAllRanges();
        toast(ok ? 'Tersalin ✓' : 'Gagal menyalin otomatis. Tekan lama teksnya untuk menyalin manual.');
      }

      // ---------- mengirim ke Mac ----------
      async function sendText() {
        const text = $('input').value;
        if (!text.trim()) { toast('Tulis atau tempel teks dulu'); $('input').focus(); return; }
        $('send').disabled = true;
        try {
          await api('/api/text', { method: 'POST', body: new TextEncoder().encode(text) });
          $('input').value = '';
          toast('Terkirim ke clipboard Mac ✓');
        } catch (e) { if (!stopped) toast('Gagal mengirim: ' + e.message); }
        finally { $('send').disabled = false; }
      }
      async function sendImage(file) {
        if (file.size > MAX_BYTES) return toast('Gambar terlalu besar (maks 30 MB)');
        toast('Mengirim gambar…');
        try {
          // isi = "<mime>\n" + byte gambar, lalu dienkripsi utuh
          const head = new TextEncoder().encode((file.type || 'application/octet-stream') + '\n');
          const bytes = new Uint8Array(await file.arrayBuffer());
          const body = new Uint8Array(head.length + bytes.length);
          body.set(head); body.set(bytes, head.length);
          await api('/api/image', { method: 'POST', body });
          toast('Gambar masuk ke clipboard Mac ✓');
        } catch (e) { if (!stopped) toast('Gagal mengirim gambar: ' + e.message); }
      }

      $('send').onclick = sendText;
      $('input').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); sendText(); } });
      $('pick').onclick = () => $('file').click();
      $('file').onchange = async e => {
        for (const f of [...e.target.files]) await sendImage(f);
        e.target.value = '';
      };
      $('input').addEventListener('paste', e => {
        const files = [...((e.clipboardData && e.clipboardData.items) || [])]
          .filter(i => i.kind === 'file' && i.type.startsWith('image/'))
          .map(i => i.getAsFile()).filter(Boolean);
        if (files.length) { e.preventDefault(); files.reduce((p, f) => p.then(() => sendImage(f)), Promise.resolve()); }
      });

      if (!key || key.length !== 32) expired(); else { showEmpty(); poll(); }
    })();
    </script>
    </body>
    </html>
    """#
}

// MARK: - Update (cek rilis terbaru di GitHub Releases)

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-PasteLAN"
    let appName = "PasteLAN"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: URL?, sig: URL?, page: URL)
    var latest: Release?
    var timer: Timer?

    /// Kunci publik Ed25519 (base64) pemilik repo, dari `swift scripts/sign-release.swift keygen`.
    /// Update otomatis hanya dipasang kalau PasteLAN.zip.sig cocok dengan kunci ini; kosong → selalu lewat halaman rilis.
    static let publicKey = "PTtPJWvtz/ZOCSWubniY+8mQwWJCb5uc/KEb9U1mGTg="

    /// Tanda tangan untuk "PasteLAN <tag>\n" + isi zip (lihat scripts/sign-release.swift)
    static func verify(zip: URL, tag: String, signature: String) -> Bool {
        guard let k = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: k),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: zip) else { return false }
        return key.isValidSignature(sig, for: Data("PasteLAN \(tag)\n".utf8) + data)
    }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "v1.2.0" lebih baru dari "1.1"?
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    /// Cek diam-diam saat aplikasi dibuka lalu sehari sekali; kalau ada versi baru, judul menu berubah
    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in self?.refreshMenu() }
        }
        t.tolerance = 3600 // tidak perlu tepat waktu → hemat energi
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate { menuItem.title = "Update tersedia: \(l.version)…" }
        else { menuItem.title = "Cek pembaruan…" }
    }

    /// Ambil info rilis terbaru; done(true) kalau berhasil (dipanggil di main thread)
    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var info: Release?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String,
               let page = (j["html_url"] as? String).flatMap({ URL(string: $0) }) {
                let assets = j["assets"] as? [[String: Any]] ?? []
                func asset(_ name: String) -> URL? {
                    (assets.first { ($0["name"] as? String) == name }?["browser_download_url"] as? String).flatMap { URL(string: $0) }
                }
                info = (tag, asset("\(self.appName).zip"), asset("\(self.appName).zip.sig"), page)
            }
            DispatchQueue.main.async {
                if let info { self.latest = info }
                done(info != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = "Periksa koneksi internet, lalu coba lagi."
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "\(self.appName) sudah versi terbaru"
                a.informativeText = "Versi terpasang: \(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "\(self.appName) \(l.version) tersedia"
            a.informativeText = "Versi terpasang: \(Updater.current).\n\n\(self.appName) akan ditutup, diganti versi baru, lalu dibuka lagi. Pengaturan & link HP tetap berlaku."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, ekstrak, lalu ganti .app lama setelah aplikasi ini keluar
    func install(_ l: Release) {
        let dest = Bundle.main.bundleURL
        // tanpa .zip / tanda tangan / kunci publik, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, let sigURL = l.sig, !Updater.publicKey.isEmpty, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        // tanda tangan dulu (kecil), lalu zip
        URLSession.shared.dataTask(with: sigURL) { sigData, _, _ in
            let signature = sigData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            URLSession.shared.downloadTask(with: zip) { tmp, _, err in
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
                let zipFile = work.appendingPathComponent("update.zip")
                let newApp = work.appendingPathComponent("\(self.appName).app")
                var problem: String?
                if let tmp {
                    do {
                        // file sementara dihapus setelah handler ini selesai → pindahkan sekarang
                        try fm.createDirectory(at: work, withIntermediateDirectories: true)
                        try fm.moveItem(at: tmp, to: zipFile)
                        // zip harus ditandatangani pemilik repo → akun / rilis GitHub yang dibobol saja tidak cukup
                        guard Updater.verify(zip: zipFile, tag: l.version, signature: signature) else {
                            throw NSError(domain: "PasteLAN", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "Tanda tangan rilis tidak cocok. Update dibatalkan demi keamanan."])
                        }
                        let unzip = Process()
                        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                        try unzip.run()
                        unzip.waitUntilExit()
                        if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                            problem = "File rilis tidak berisi \(self.appName).app."
                        } else if Bundle(url: newApp)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                            problem = "File rilis berisi aplikasi lain."
                        }
                    } catch { problem = error.localizedDescription }
                } else {
                    problem = err?.localizedDescription ?? "Unduhan gagal."
                }
                DispatchQueue.main.async {
                    if let problem { return self.fail(problem, l.page) }
                    // skrip kecil: tunggu aplikasi ini keluar, tukar .app (lama dicadangkan dulu), lalu buka lagi
                    let script = """
                    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                    if mv "$3" "$4"; then
                      if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                    fi
                    xattr -cr "$3" 2>/dev/null
                    open "$3"
                    """
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                                   work.appendingPathComponent("old.app").path]
                    do { try p.run() } catch { return self.fail(error.localizedDescription, l.page) }
                    NSApp.terminate(nil)
                }
            }.resume()
        }.resume()
    }

    func fail(_ msg: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = "\(msg)\n\nHalaman rilis akan dibuka supaya Anda bisa mengunduh manual."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        NSWorkspace.shared.open(page)
    }
}

// MARK: - Aplikasi

/// Kotak teks tanpa latar sama sekali: saat diketik, macOS memasang "field editor" (NSTextView) yang menggambar
/// kotak latar gelap/terang sendiri → latarnya dimatikan setiap kali kotak ini mulai diedit
final class PlainTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        clearEditorBackground()
        return ok
    }

    override func textDidBeginEditing(_ n: Notification) {
        super.textDidBeginEditing(n)
        clearEditorBackground()
    }

    private func clearEditorBackground() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.enclosingScrollView?.drawsBackground = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    /// Lebar tetap & ikon kecil → ikon di menu bar tidak makan tempat (variableLength memberi jarak kiri-kanan lebih lebar)
    let item = NSStatusBar.system.statusItem(withLength: 18)
    let menu = NSMenu()
    let d = UserDefaults.standard
    let updater = Updater()
    let server = PasteServer()
    let clipboard = Clipboard()
    lazy var lan = LANServer(clipboard: clipboard)
    let macName = computerName()
    let history = History()
    /// Salinan riwayat di disk (Pengaturan → Umum → "Simpan riwayat di Mac"; dimatikan → hanya di memori)
    lazy var historyStore = HistoryStore(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteLAN/History", isDirectory: true))
    var historyPersist: Bool { d.bool(forKey: "historyPersist") }
    lazy var settings = SettingsWindow(app: self)
    /// Kotak cari di menu: teks polos tanpa bingkai (hanya ikon kaca pembesar + placeholder), setinggi satu baris menu
    let searchField = PlainTextField(frame: NSRect(x: 36, y: 3, width: 250, height: 18))
    var flashTimer: Timer?
    var menuOpen = false
    var lastDeleted: (clip: LocalClip, index: Int)? // untuk "Urungkan hapus" (satu clip terakhir)

    /// Autosync dengan server / HP: setiap copy di Mac otomatis terkirim & kiriman dari HP otomatis masuk.
    /// Mati = clipboard manager offline biasa (riwayat tetap dicatat); satu clip masih bisa dikirim lewat ⇧ + klik.
    var sharing: Bool { d.bool(forKey: "sharing") }
    var serverURL: URL? { d.string(forKey: "serverURL").flatMap(PasteServer.normalize) }
    var loggedIn: Bool { server.token != nil }
    /// Autosync aktif dan metodenya siap (Wi-Fi lokal, atau sudah login ke server)
    var syncActive: Bool { sharing && (lanMode || loggedIn) }
    /// Jumlah clip yang diingat di riwayat Mac
    var historyLimit: Int { max(5, d.integer(forKey: "historyLimit")) }
    static let historyLimits = [10, 15, 20, 30, 50, 100]
    /// Metode: "server" (default, lewat server PasteLAN) atau "lan" (Wi-Fi lokal tanpa server)
    var lanMode: Bool { d.string(forKey: "mode") == "lan" }

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: ["sharing": true, "saveImages": false, "mode": "server", "historyLimit": 15,
                              "historyPersist": true])
        d.removeObject(forKey: "token") // link Wi-Fi lokal lama (v0.1.x, token di ?t=) tidak berlaku lagi
        // "Kirim setiap copy otomatis" (≤ v1.7) digabung ke autosync: yang dulu mematikannya → autosync mati
        // (copy di Mac tetap tidak terkirim otomatis; kirim satu clip lewat ⇧ + klik)
        if d.object(forKey: "autoSend") != nil {
            if !d.bool(forKey: "autoSend") { d.set(false, forKey: "sharing") }
            d.removeObject(forKey: "autoSend")
        }

        item.autosaveName = "PasteLAN" // posisi ikon diingat
        item.button?.toolTip = "PasteLAN — copy-paste Mac ⇄ HP"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        server.configure(base: serverURL, token: Keychain.token)
        server.onChange = { [weak self] in self?.updateIcon() }
        server.onIncoming = { [weak self] c in self?.receive(c) }
        server.onSeen = { [weak self] c in self?.seen(c) }
        server.onUnauthorized = { [weak self] in self?.loginExpired() }
        lan.http.onChange = { [weak self] in self?.updateIcon() }
        lan.onPhone = { [weak self] c in self?.receivedFromLAN(c) }
        clipboard.onChange = { [weak self] in self?.copiedOnMac() }
        history.limit = historyLimit
        history.onChange = { [weak self] in self?.historyChanged() }
        if historyPersist { historyStore.load(into: history) } // sebelum sinkron mulai
        searchField.placeholderString = "Cari clip…"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .menuFont(ofSize: 0)
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self
        NSApp.mainMenu = editMenu()

        applySharing()
        updater.start()

        if !d.bool(forKey: "didOnboard") {
            d.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showHelp()
                self.askAutosync()
                if !self.lanMode, !self.loggedIn { self.setupServer() }
            }
        } else if !lanMode, !loggedIn, !d.bool(forKey: "askedServer") {
            // update dari versi Wi-Fi lokal (v0.x): minta alamat server sekali (atau pilih tetap Wi-Fi lokal)
            d.set(true, forKey: "askedServer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setupServer() }
        }
    }

    // MARK: berbagi

    /// Hanya satu metode yang jalan: saat memakai server, port lokal di Mac tertutup (dan sebaliknya)
    func applySharing() {
        let active = sharing && (lanMode || loggedIn)
        if active, lanMode {
            server.stop()
            lan.start()
        } else if active {
            lan.stop()
            if !server.running { server.start() }
        } else {
            server.stop()
            lan.stop()
        }
        clipboard.startWatching() // riwayat Mac selalu dicatat (clipboard manager), juga saat sinkron mati
        updateIcon()
        settings.reload()
    }

    /// Aplikasi menu bar tidak punya menu utama → tanpa ini ⌘C / ⌘V / ⌘A / ⌘W tidak jalan di jendela & dialog
    func editMenu() -> NSMenu {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Urungkan", Selector(("undo:")), "z"), ("Potong", #selector(NSText.cut(_:)), "x"),
                                     ("Salin", #selector(NSText.copy(_:)), "c"), ("Tempel", #selector(NSText.paste(_:)), "v"),
                                     ("Pilih semua", #selector(NSText.selectAll(_:)), "a"),
                                     ("Tutup jendela", #selector(NSWindow.performClose(_:)), "w")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let it = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        it.submenu = edit
        main.addItem(it)
        return main
    }

    /// Lebar item mengikuti lebar gambar + 4 pt (2 pt kiri-kanan) → titik status tidak terpotong, tetap rapat
    func setBarImage(_ img: NSImage?) {
        item.button?.image = img
        item.length = max(16, ceil((img?.size.width ?? 14) + 4))
    }

    func updateIcon() {
        guard let b = item.button else { return }
        // ikon tidak pernah diredupkan: sinkron mati tetap terlihat normal (clipboard manager tetap jalan)
        let connected = lanMode ? lan.running : server.state == .connected
        let badge: BarBadge = !syncActive ? .none : connected ? .on : .waiting
        if flashTimer == nil { setBarImage(barIcon("paperclip", badge: badge)) }
        b.appearsDisabled = false
        b.toolTip = "PasteLAN — " + (!syncActive ? "autosync mati, clipboard manager offline"
                                                 : connected ? "autosync aktif" : "autosync aktif, menghubungkan…")
        settings.reloadStatus()
    }

    /// Ikon ✓ sebentar saat menerima sesuatu dari HP
    func flash() {
        flashTimer?.invalidate()
        setBarImage(barIcon("checkmark.circle.fill"))
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.flashTimer = nil
            self?.updateIcon()
        }
    }

    /// Setiap copy di Mac masuk riwayat; dikirim ke server / HP hanya kalau autosync aktif.
    /// Copy selama autosync mati tetap "Hanya di Mac" (tidak ikut terkirim saat autosync dinyalakan lagi).
    func copiedOnMac() {
        guard let c = clipboard.read() else { return }
        let clip = history.add(c, from: "", synced: false)
        if syncActive { push(clip) }
    }

    /// Bisa mengirim satu clip dari menu (⇧ + klik)? Mode server cukup sudah login: saat autosync mati clip dikirim
    /// sekali saja (tanpa menyalakan autosync). Wi-Fi lokal butuh autosync aktif karena server kecil di Mac mati saat autosync mati.
    var canSendOne: Bool { lanMode ? syncActive : loggedIn }

    /// Kirim clip dari riwayat Mac ke server / HP. false kalau tidak bisa (autosync mati, atau gambar tanpa isi).
    /// `once`: kiriman manual satu clip, boleh juga saat autosync mati (lihat canSendOne).
    @discardableResult
    func push(_ c: LocalClip, once: Bool = false) -> Bool {
        guard once ? canSendOne : syncActive else { return false }
        let content: PasteContent
        if let text = c.text { content = PasteContent(kind: "text", text: text, data: nil, mime: nil) }
        else if let data = c.data { content = PasteContent(kind: "image", text: nil, data: data, mime: c.mime) }
        else { return false }
        if lanMode {
            lan.add(content)
            c.synced = true
            history.changed()
            return true
        }
        let done: (Int?) -> Void = { [weak self] id in
            guard let id else { return }
            c.synced = true
            c.serverID = id
            self?.history.changed()
        }
        if let text = content.text { server.sendText(text, done) } else if let data = content.data { server.sendImage(data, done) }
        return true
    }

    /// Item baru dari perangkat lain → langsung masuk clipboard Mac (dan riwayat)
    func receive(_ c: Clip) {
        if c.kind == "text", let text = c.text {
            clipboard.writeText(text)
            history.add(kind: "text", text: text, data: nil, mime: nil, size: c.size, from: c.from, synced: true, serverID: c.id)
            flash()
        } else if c.kind == "image" {
            server.image(c.id) { [weak self] data in
                guard let self, let data, self.clipboard.writeImage(data, mime: c.mime) else { return }
                self.history.add(kind: "image", text: nil, data: data, mime: c.mime, size: data.count, from: c.from,
                                 synced: true, serverID: c.id)
                if self.d.bool(forKey: "saveImages") { self.saveToDownloads(data, mime: c.mime) }
                self.flash()
            }
        }
    }

    /// Item yang sudah ada di server saat Mac (baru) tersambung: hanya masuk riwayat, tidak ditempel ke clipboard.
    /// Isi gambar baru diambil saat clip itu dipilih.
    func seen(_ c: Clip) {
        let mine = c.device == server.me
        history.add(kind: c.kind, text: c.text, data: nil, mime: c.mime, size: c.size, from: mine ? "" : c.from,
                    synced: true, serverID: c.id, time: c.date, bump: false)
    }

    /// Item dari HP lewat Wi-Fi lokal (sudah masuk clipboard Mac)
    func receivedFromLAN(_ c: LANClip) {
        history.add(kind: c.kind, text: c.text, data: c.data, mime: c.mime, size: c.size, from: "HP", synced: true)
        if c.kind == "image", let data = c.data, d.bool(forKey: "saveImages") { saveToDownloads(data, mime: c.mime) }
        flash()
    }

    func historyChanged() {
        if menuOpen { refreshHistoryItems() }
        settings.reloadClips()
        if historyPersist { historyStore.saveSoon(history) }
    }

    /// Riwayat ditulis ke disk sebentar setelah berubah → pastikan tersimpan saat aplikasi ditutup
    func applicationWillTerminate(_ n: Notification) {
        if historyPersist { historyStore.save(history) }
    }

    func setHistoryPersist(_ on: Bool) {
        d.set(on, forKey: "historyPersist")
        if on { historyStore.save(history) } else { historyStore.wipe() }
    }

    /// Pertama kali dipakai: pengguna memilih sendiri apakah setiap copy di Mac langsung tersedia untuk HP (autosync)
    func askAutosync() {
        let a = NSAlert()
        a.messageText = "Nyalakan autosync?"
        a.informativeText = "Autosync: semua yang Anda copy (⌘C) di Mac otomatis muncul di HP / browser yang login ke server " +
            "PasteLAN, dan kiriman dari HP otomatis masuk ke clipboard Mac.\n\n" +
            "Kalau tidak, PasteLAN jadi clipboard manager offline biasa: semua copy hanya dicatat di riwayat Mac. " +
            "Satu clip tetap bisa dikirim kapan saja: tahan ⇧ (Shift) lalu klik clip itu di menu. " +
            "Bisa diubah kapan saja di menu atau Pengaturan."
        a.addButton(withTitle: "Nyalakan autosync")
        a.addButton(withTitle: "Offline saja")
        NSApp.activate(ignoringOtherApps: true)
        d.set(a.runModal() == .alertFirstButtonReturn, forKey: "sharing")
        applySharing()
    }

    func saveToDownloads(_ data: Data, mime: String?) {
        guard let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "PasteLAN-\(f.string(from: Date()))", ext = fileExt(mime)
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        try? data.write(to: url)
    }

    // MARK: server & login

    /// Minta link setup (dari halaman admin), atau alamat server + password, lalu login
    /// (link / password tidak disimpan; token disimpan di Keychain)
    @objc func setupServer() {
        let a = NSAlert()
        a.messageText = "Server PasteLAN"
        a.informativeText = "Tempel link setup dari halaman admin server (https://server/admin → \"Buat link setup\"), " +
            "password tidak perlu diisi.\n\nAtau isi alamat server dan password perangkat. Mac ini lalu menyimpan " +
            "token perangkat di Keychain."
        let urlField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        urlField.placeholderString = "Link setup atau pastelan.example.com"
        urlField.stringValue = d.string(forKey: "serverURL") ?? ""
        let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        pwField.placeholderString = "Password (kosongkan kalau pakai link setup)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        box.addSubview(urlField)
        box.addSubview(pwField)
        a.accessoryView = box
        a.addButton(withTitle: "Login")
        a.addButton(withTitle: "Batal")
        a.addButton(withTitle: "Pakai Wi-Fi lokal saja")
        a.window.initialFirstResponder = urlField.stringValue.isEmpty ? urlField : pwField
        NSApp.activate(ignoringOtherApps: true)
        let choice = a.runModal()
        if choice == .alertThirdButtonReturn { return setMode("lan") }
        guard choice == .alertFirstButtonReturn else { return }
        let link = PasteServer.setupLink(urlField.stringValue)
        if link == nil, urlField.stringValue.contains("#pair=") {
            return showError("Link setup tidak valid", "Salin ulang link setup dari halaman admin server PasteLAN.")
        }
        guard let url = link?.base ?? PasteServer.normalize(urlField.stringValue) else {
            return showError("Alamat server tidak valid", "Pakai alamat HTTPS server PasteLAN, mis. pastelan.example.com.")
        }
        let password = pwField.stringValue
        let doLogin = { [weak self] in
            guard let self else { return }
            let done: (String?, String?) -> Void = { token, err in
                guard let token else { return self.showError("Login gagal", err ?? "Tidak diketahui") }
                Keychain.token = token
                self.d.set(url.absoluteString, forKey: "serverURL")
                self.d.set("server", forKey: "mode")
                self.applySharing()
            }
            if let link {
                self.server.claim(base: link.base, code: link.code, name: self.macName, done)
            } else {
                self.server.login(base: url, password: password, name: self.macName, done)
            }
        }
        // ganti server / login ulang → token lama dicabut dulu di server lama
        if loggedIn { server.logout(doLogin) } else { doLogin() }
    }

    func showError(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: "Coba lagi")
        a.addButton(withTitle: "Tutup")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { setupServer() }
    }

    /// Token Mac ini dicabut (dari halaman PasteLAN) / tidak berlaku lagi
    func loginExpired() {
        Keychain.token = nil
        applySharing()
        showError("Login PasteLAN berakhir", "Mac ini dikeluarkan dari server PasteLAN (perangkat dicabut atau server diganti). Login lagi?")
    }

    @objc func logoutServer() {
        let a = NSAlert()
        a.messageText = "Keluar dari server PasteLAN?"
        a.informativeText = "Token Mac ini dicabut di server. Untuk tersambung lagi perlu link setup (dari halaman admin) " +
            "atau password perangkat."
        a.addButton(withTitle: "Keluar")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        server.logout {}
        Keychain.token = nil
        applySharing()
    }

    /// QR sekali pakai (5 menit): HP scan → langsung masuk tanpa mengetik password.
    /// Kode hanya dibuat saat diminta (bukan setiap menu dibuka), supaya QR yang berlaku tidak sering tampil di layar.
    @objc func pairPhone() {
        server.pairLink { [weak self] url, expires, err in
            guard let self else { return }
            guard let url, let expires else { return self.showError("Gagal membuat QR", err ?? "Tidak diketahui") }
            let f = DateFormatter()
            f.dateFormat = "HH.mm"
            let a = NSAlert()
            a.messageText = "Tambah HP ke PasteLAN"
            a.informativeText = "Scan dengan kamera HP. HP langsung masuk tanpa password, lalu pilih \"Install\" / " +
                "\"Tambahkan ke Layar Utama\".\n\nQR ini hanya untuk satu HP dan berlaku sampai \(f.string(from: expires)). " +
                "Jangan bagikan / foto layar ini."
            let qr: CGFloat = 220
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: qr, height: qr))
            iv.image = qrImage(url.absoluteString, points: qr)
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor.white.cgColor // QR selalu di atas putih supaya terbaca kamera
            iv.layer?.cornerRadius = 6
            a.accessoryView = iv
            a.addButton(withTitle: "Selesai")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc func openWeb() {
        if let url = serverURL { NSWorkspace.shared.open(url) }
    }

    // MARK: menu (dibangun ulang setiap dibuka → status & riwayat selalu terbaru)

    var statusText: String {
        let host = serverURL?.host ?? "server"
        guard loggedIn else { return "Belum login ke server PasteLAN" }
        guard sharing else { return "Autosync mati · clipboard manager offline" }
        switch server.state {
        case .loggedOut: return "Belum login ke server PasteLAN"
        case .connecting: return "Menghubungkan ke \(host)…"
        case .connected: return "Terhubung ke \(host)"
        case .offline(let e): return "Tidak bisa menghubungi \(host): \(e.count > 50 ? String(e.prefix(50)) + "…" : e)"
        }
    }

    /// Susunan menu (gaya Clipy): kotak cari + riwayat clip di atas (⌘0–⌘9 untuk 10 teratas), lalu satu bagian berisi
    /// status, tambah HP, buka browser, autosync, clipboard manager & Pengaturan (jendela sendiri), terakhir "Keluar".
    /// "…" hanya untuk item yang membuka dialog / meminta isian lagi (konvensi macOS), bukan karena teksnya terpotong.
    func menuNeedsUpdate(_ m: NSMenu) {
        menu.removeAllItems()
        updater.menuItem.menu?.removeItem(updater.menuItem)
        searchField.stringValue = ""

        addHistorySection()
        menu.addItem(.separator())
        if lanMode { addLANSection() } else { addServerSection() }
        let sync = add(lanMode ? "Autosync dengan HP (Wi-Fi lokal)" : "Autosync dengan server & browser", #selector(toggleSharing), on: sharing)
        sync.image = symbol("arrow.triangle.2.circlepath")
        sync.toolTip = "Nyala: setiap copy di Mac otomatis terkirim, kiriman dari HP otomatis masuk. " +
            (lanMode ? "Mati: clipboard manager offline biasa (server Wi-Fi lokal di Mac ikut mati). "
                     : "Mati: clipboard manager offline biasa; tahan ⇧ lalu klik sebuah clip untuk mengirimnya. ") +
            "Saat dinyalakan lagi, hanya copy baru yang dikirim."
        let manager = add("Clipboard manager", #selector(openClipboardManager))
        manager.image = symbol("list.bullet.rectangle")
        let pref = add("Pengaturan…", #selector(openSettings))
        pref.keyEquivalent = ","
        pref.image = symbol("gearshape")
        if updater.hasUpdate { menu.addItem(updater.menuItem) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Keluar PasteLAN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ m: NSMenu) { menuOpen = true }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    /// Pencarian di menu: daftar clip disaring setiap huruf diketik (menu tetap terbuka)
    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === searchField { refreshHistoryItems() }
    }

    /// Jumlah clip yang tampil langsung di menu; sisanya di submenu "Riwayat lainnya"
    let inlineClips = 20
    let historyTag = 77

    lazy var searchBox: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let glass = NSImageView(frame: NSRect(x: 14, y: 4, width: 16, height: 16))
        glass.image = symbol("magnifyingglass")
        glass.contentTintColor = .secondaryLabelColor
        v.addSubview(glass)
        self.searchField.autoresizingMask = [.width]
        v.addSubview(self.searchField)
        return v
    }()

    func addHistorySection() {
        let search = NSMenuItem()
        search.view = searchBox
        menu.addItem(search)
        insertHistoryItems(at: menu.numberOfItems)
        menu.addItem(.separator())
        if let last = lastDeleted {
            let undo = add("Urungkan hapus \"\(last.clip.title)\"", #selector(undoDelete))
            undo.image = symbol("arrow.uturn.backward")
        }
        let clear = add("Hapus riwayat…", #selector(clearHistory), enabled: !history.items.isEmpty)
        clear.tag = historyTag + 1
    }

    /// Baris clip (bertanda historyTag) disisipkan mulai `start`; dipanggil ulang saat pencarian / riwayat berubah
    func insertHistoryItems(at start: Int) {
        var i = start
        func put(_ it: NSMenuItem) {
            it.tag = historyTag
            menu.insertItem(it, at: i)
            i += 1
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = history.items.filter { $0.matches(query) }
        if list.isEmpty {
            let e = NSMenuItem(title: history.items.isEmpty ? "Belum ada riwayat. Copy sesuatu di Mac atau kirim dari HP."
                                                            : "Tidak ada clip yang cocok dengan \"\(query)\"",
                               action: nil, keyEquivalent: "")
            e.isEnabled = false
            put(e)
        }
        var more: NSMenu?
        for (n, c) in list.enumerated() {
            // ⌘0 … ⌘9 untuk sepuluh clip teratas (berlaku selama menu terbuka)
            let it = NSMenuItem(title: c.title, action: #selector(recopy(_:)), keyEquivalent: n < 10 ? "\(n)" : "")
            it.target = self
            it.representedObject = c.id
            it.toolTip = "Dari \(c.source)" + (c.pending ? " · belum dikirim ke server / HP" : "") +
                " · klik untuk menyalin ke clipboard Mac, tahan ⇧ untuk mengirim, tahan ⌥ untuk menghapus"
            // tahan ⌥ → baris ini berganti jadi "Hapus" (alternate item: harus tepat setelah item utamanya,
            // tombol pintas sama dengan modifier berbeda → ⌥⌘0–⌥⌘9 menghapus)
            let del = NSMenuItem(title: "Hapus: \(c.title)", action: #selector(deleteClip(_:)), keyEquivalent: it.keyEquivalent)
            del.keyEquivalentModifierMask = it.keyEquivalent.isEmpty ? [.option] : [.command, .option]
            del.isAlternate = true
            del.target = self
            del.representedObject = c.id
            del.image = symbol("trash")
            del.toolTip = "Hapus dari riwayat Mac ini (tidak menghapus di server / HP)"
            // tahan ⇧ → "Kirim": kirim clip ini saja ke server / HP (berguna saat autosync mati)
            let send = NSMenuItem(title: canSendOne ? "Kirim: \(c.title)" : "Kirim (nyalakan autosync dulu): \(c.title)",
                                  action: #selector(sendClip(_:)), keyEquivalent: it.keyEquivalent)
            send.keyEquivalentModifierMask = it.keyEquivalent.isEmpty ? [.shift] : [.command, .shift]
            send.isAlternate = true
            send.isEnabled = canSendOne
            send.target = self
            send.representedObject = c.id
            send.image = symbol("arrow.up.circle")
            send.toolTip = lanMode ? "Kirim clip ini ke HP (Wi-Fi lokal)" : "Kirim clip ini ke server & browser"
            if n < inlineClips {
                put(it)
                put(del)
                put(send)
            } else {
                if more == nil {
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    let mi = NSMenuItem(title: "Riwayat lainnya (\(list.count - inlineClips))", action: nil, keyEquivalent: "")
                    mi.submenu = sub
                    put(mi)
                    more = sub
                }
                more?.addItem(it)
                more?.addItem(del)
                more?.addItem(send)
            }
        }
        if !list.isEmpty {
            let tip = NSMenuItem(title: "Tahan ⇧ untuk mengirim clip · tahan ⌥ untuk menghapus", action: nil, keyEquivalent: "")
            tip.attributedTitle = NSAttributedString(string: tip.title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.tertiaryLabelColor])
            tip.isEnabled = false
            put(tip)
        }
    }

    func refreshHistoryItems() {
        guard let first = menu.items.firstIndex(where: { $0.tag == historyTag }) else { return }
        for it in menu.items where it.tag == historyTag { menu.removeItem(it) }
        insertHistoryItems(at: first)
        menu.items.first(where: { $0.tag == historyTag + 1 })?.isEnabled = !history.items.isEmpty
    }

    func addServerSection() {
        let st = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        st.isEnabled = false
        st.image = statusDot(sharing && loggedIn && server.state == .connected)
        menu.addItem(st)
        if loggedIn, serverURL != nil {
            add("Tambah HP (scan QR)…", #selector(pairPhone)).image = symbol("qrcode.viewfinder")
            add("Buka PasteLAN di browser", #selector(openWeb)).image = symbol("safari")
        } else {
            add("Atur server & login…", #selector(setupServer)).image = symbol("server.rack")
        }
    }

    /// Wi-Fi lokal: status di menu utama, QR code & link di submenu "Tambah HP" supaya menu tetap ringkas
    func addLANSection() {
        guard sharing else {
            let st = NSMenuItem(title: "Autosync mati · clipboard manager offline", action: nil, keyEquivalent: "")
            st.isEnabled = false
            st.image = statusDot(false)
            menu.addItem(st)
            return
        }
        let url = lan.shareURL
        let info: String
        if lan.http.failed { info = "Server gagal berjalan: port \(lan.port)–\(lan.port + 11) sibuk." }
        else if !lan.running { info = "Menyalakan server…" }
        else if url == nil { info = "Mac belum terhubung ke Wi-Fi / jaringan lokal." }
        else { info = "Scan dengan kamera HP (Wi-Fi yang sama)" }
        let n = lan.connectedCount
        let st = NSMenuItem(title: url == nil ? info : (n > 0 ? "Wi-Fi lokal · \(n) perangkat terhubung" : "Wi-Fi lokal · belum ada perangkat"),
                            action: nil, keyEquivalent: "")
        st.isEnabled = false
        st.image = statusDot(lan.running && url != nil)
        menu.addItem(st)

        let pair = NSMenuItem(title: "Tambah HP (scan QR)", action: nil, keyEquivalent: "")
        pair.image = symbol("qrcode.viewfinder")
        let pm = NSMenu()
        pm.autoenablesItems = false
        let qr = NSMenuItem()
        qr.view = qrView(url: url, info: info)
        pm.addItem(qr)
        if url != nil { add("Salin link", #selector(copyLink), to: pm) }
        if lan.running {
            // HP tidak bisa membuka halaman? Kalau di sini tidak muncul IP HP, permintaannya tidak sampai ke Mac
            let text: String
            if let p = lan.http.lastPeer {
                let f = DateFormatter()
                f.dateFormat = "HH.mm.ss"
                text = "Koneksi masuk terakhir: \(p.host), \(f.string(from: p.time)) (\(p.note))"
            } else {
                text = "Belum ada koneksi masuk sejak server dimulai"
            }
            let lp = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            lp.isEnabled = false
            pm.addItem(lp)
        }
        pair.submenu = pm
        menu.addItem(pair)
    }

    /// Titik status kecil (hijau = tersambung, abu-abu = tidak) di depan baris status
    func statusDot(_ on: Bool) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            (on ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @discardableResult
    func add(_ title: String, _ action: Selector, on: Bool? = nil, enabled: Bool = true, to target: NSMenu? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled
        if let on { it.state = on ? .on : .off }
        (target ?? menu).addItem(it)
        return it
    }

    /// QR code + alamat, ditampilkan langsung di dalam menu
    func qrView(url: String?, info: String) -> NSView {
        let w: CGFloat = 260, qr: CGFloat = 190
        let h: CGFloat = url == nil ? 44 : qr + 62
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let label = NSTextField(wrappingLabelWithString: info)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 14, y: 6, width: w - 28, height: 32)
        v.addSubview(label)

        guard let url else { return v }
        // alamat tanpa kunci (#k=…) & tanpa https://
        let shown = (url.components(separatedBy: "/#").first ?? url).replacingOccurrences(of: "https://", with: "")
        let addr = NSTextField(labelWithString: shown)
        addr.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        addr.alignment = .center
        addr.lineBreakMode = .byTruncatingMiddle
        addr.frame = NSRect(x: 14, y: 36, width: w - 28, height: 18)
        v.addSubview(addr)

        let iv = NSImageView(frame: NSRect(x: (w - qr) / 2, y: 58, width: qr, height: qr))
        iv.image = qrImage(url, points: qr)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.white.cgColor // QR selalu di atas putih supaya terbaca kamera
        iv.layer?.cornerRadius = 6
        v.addSubview(iv)
        return v
    }

    // MARK: aksi

    /// Autosync dinyalakan lagi → hanya copy berikutnya yang dikirim; riwayat lama bisa dikirim dari Clipboard manager
    @objc func toggleSharing() {
        d.set(!sharing, forKey: "sharing")
        applySharing()
    }
    @objc func openSettings() { settings.show(.general) }
    @objc func openClipboardManager() { settings.show(.clipboard) }
    func setHistoryLimit(_ n: Int) {
        d.set(n, forKey: "historyLimit")
        history.limit = historyLimit
    }
    @objc func toggleSaveImages() {
        d.set(!d.bool(forKey: "saveImages"), forKey: "saveImages")
    }
    @objc func recopy(_ s: NSMenuItem) {
        if let id = s.representedObject as? Int { copyToClipboard(id) }
    }
    /// Salin clip dari riwayat ke clipboard Mac (tidak dikirim ulang ke server); clip itu naik ke paling atas
    func copyToClipboard(_ id: Int) {
        guard let c = history.clip(id) else { return }
        if let text = c.text { clipboard.writeText(text) }
        else if let data = c.data { _ = clipboard.writeImage(data, mime: c.mime) }
        else if let sid = c.serverID, !lanMode, loggedIn {
            server.image(sid) { [weak self] data in
                guard let self, let data else { return }
                c.data = data
                _ = self.clipboard.writeImage(data, mime: c.mime)
            }
        }
        history.bump(id)
    }
    /// ⌥ + klik (atau ⌥⌘0–9): hapus satu clip dari riwayat Mac, tanpa konfirmasi; bisa diurungkan dari menu
    /// ⇧ + klik: kirim satu clip ke server / HP (di mode server juga saat autosync mati)
    @objc func sendClip(_ s: NSMenuItem) {
        guard let id = s.representedObject as? Int, let c = history.clip(id) else { return }
        if push(c, once: true) { return flash() }
        let a = NSAlert()
        a.messageText = "Clip tidak terkirim"
        if !canSendOne {
            a.informativeText = lanMode ? "Wi-Fi lokal: nyalakan \"Autosync dengan HP\" dulu di menu PasteLAN."
                                        : "Mac ini belum login ke server PasteLAN (Pengaturan… → Koneksi)."
        } else {
            a.informativeText = "Gambar ini berasal dari server dan isinya belum diambil ke Mac (memang sudah ada di server)."
        }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
    @objc func deleteClip(_ s: NSMenuItem) {
        guard let id = s.representedObject as? Int, let r = history.take(id) else { return }
        lastDeleted = r
    }
    @objc func undoDelete() {
        guard let r = lastDeleted else { return }
        lastDeleted = nil
        history.restore(r.clip, at: r.index)
    }
    @objc func clearHistory() {
        let a = NSAlert()
        let remote = lanMode ? "HP" : "server"
        a.messageText = "Hapus riwayat clipboard?"
        a.informativeText = syncActive
            ? "Riwayat di Mac ini dikosongkan. Pilih \"Hapus juga di \(remote)\" untuk mengosongkan riwayat di semua perangkat."
            : "Riwayat di Mac ini dikosongkan. Riwayat di \(remote) tidak berubah."
        a.addButton(withTitle: "Hapus di Mac ini")
        a.addButton(withTitle: "Batal")
        if syncActive { a.addButton(withTitle: "Hapus juga di \(remote)") }
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            history.clear()
            lastDeleted = nil
        case .alertThirdButtonReturn:
            history.clear()
            lastDeleted = nil
            // semua perangkat menerima session baru → daftarnya dikosongkan
            if lanMode { lan.clearHistory() } else { server.clearHistory() }
        default: break
        }
    }
    @objc func useServerMode() { setMode("server") }
    @objc func useLANMode() { setMode("lan") }

    func setMode(_ mode: String) {
        guard d.string(forKey: "mode") != mode else { return }
        d.set(mode, forKey: "mode")
        applySharing()
        if mode == "server", !loggedIn { setupServer() }
    }
    @objc func copyLink() {
        guard let url = lan.shareURL else { return }
        // link berisi kunci → jangan ikut Universal Clipboard (perangkat Apple lain) & tandai rahasia untuk clipboard manager
        let pb = clipboard.pb
        _ = pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(url, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        clipboard.markOwnWrite()
    }
    /// Kunci baru + server Wi-Fi lokal dimulai ulang (port & IP dibaca ulang) → semua link lama tidak berlaku
    @objc func resetLink() {
        let a = NSAlert()
        a.messageText = "Reset link PasteLAN?"
        a.informativeText = "Link diganti dan server dimulai ulang. Semua HP yang terhubung akan terputus dan harus " +
            "scan QR code yang baru.\n\nPakai ini juga kalau HP tidak bisa membuka halaman PasteLAN."
        a.addButton(withTitle: "Reset link")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        lan.resetLink()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan PasteLAN.app ada di folder Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }
    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "Cara pakai PasteLAN"
        a.informativeText = """
        PasteLAN memindahkan teks & gambar antara Mac dan HP lewat server PasteLAN milik Anda sendiri (HTTPS). \
        Mac dan HP tidak perlu di Wi-Fi yang sama.

        1. Buka https://server-anda/admin → "Buat link setup", lalu di Mac klik ikon penjepit kertas di menu bar → \
        "Atur server & login…" dan tempel link itu (atau isi alamat server + password perangkat).
        2. Menu → "Tambah HP (scan QR)…", scan dengan kamera HP (HP langsung masuk tanpa password), lalu pilih \
        "Install" / "Tambahkan ke Layar Utama" supaya PasteLAN jadi aplikasi di HP. \
        Bisa juga: buka alamat server di HP dan masuk dengan password.
        3. HP → Mac: tempel teks atau pilih gambar, tekan "Kirim", lalu ⌘V di Mac.
        4. Mac → HP: copy apa saja di Mac (⌘C), isinya muncul di HP. Tekan "Salin".

        Keamanan: semua lewat HTTPS. Isi clipboard hanya disimpan di memori server (maks 20 item, \
        hilang setelah 24 jam / saat server restart). Isi dari password manager tidak pernah dikirim. \
        Perangkat yang hilang bisa dicabut dari halaman PasteLAN → Pengaturan.

        Riwayat: klik salah satu clip di bagian atas menu (atau tekan ⌘0–⌘9 saat menu terbuka) untuk menyalinnya \
        lagi ke clipboard Mac. Klik kotak "Cari clip…" di menu untuk mencari. \
        Tahan ⇧ (Shift) lalu klik sebuah clip untuk mengirim clip itu saja ke server / HP (di mode server juga saat \
        autosync mati). \
        Tahan ⌥ (Option) lalu klik sebuah clip (atau ⌥⌘0–⌥⌘9) untuk menghapusnya dari riwayat Mac; \
        "Urungkan hapus" di menu mengembalikannya. Jumlah clip yang diingat diatur di \
        Pengaturan → Umum.

        Autosync: "Autosync dengan server & browser" di menu membuat setiap copy di Mac otomatis terkirim dan kiriman \
        dari HP otomatis masuk. Kalau dimatikan, PasteLAN jadi clipboard manager offline biasa: semua copy tetap masuk \
        riwayat Mac, tapi tidak dikirim; satu clip masih bisa dikirim dengan ⇧ + klik. Saat dinyalakan lagi hanya copy \
        baru yang dikirim; clip lama bisa dicentang lalu dikirim dari menu → "Clipboard manager".

        Tanpa server: menu → Pengaturan → Koneksi → "Wi-Fi lokal". Mac dan HP harus di Wi-Fi yang sama (atau Mac memakai \
        hotspot HP); scan QR code di menu → "Tambah HP". Isi dienkripsi dengan kunci di QR code. Wi-Fi kantor / kampus / \
        publik sering memblokir antar-perangkat. Pengaturan → Koneksi → "Reset link" memutus semua HP yang pernah terhubung.
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Hapus PasteLAN dari Mac: token di server, login item, pengaturan, lalu .app dipindahkan ke Tong Sampah
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall PasteLAN?"
        a.informativeText = "Mac ini dikeluarkan dari server PasteLAN, PasteLAN dihapus dari 'Buka saat login', pengaturannya dihapus, lalu PasteLAN.app dipindahkan ke Tong Sampah dan aplikasi ditutup."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // cabut token di server dulu (tunggu maks 3 detik kalau server tidak menjawab)
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.finishUninstall()
        }
        if loggedIn { server.logout(finish) } else { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    }

    func finishUninstall() {
        lan.stop()
        historyStore.wipe()
        Keychain.token = nil
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            d.removePersistentDomain(forName: id)
            d.synchronize()
        }
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension != "app" || (try? FileManager.default.trashItem(at: appURL, resultingItemURL: nil)) == nil {
            // tidak punya izin tulis (mis. dipasang oleh admin lain) → minta pengguna menghapus manual
            let f = NSAlert()
            f.messageText = "PasteLAN.app tidak bisa dipindahkan otomatis"
            f.informativeText = "Pengaturan sudah dihapus. Seret PasteLAN.app ke Tong Sampah secara manual."
            f.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Jendela Pengaturan (tab Umum, Koneksi, Clipboard, Tentang)

/// Kartu berlatar gaya System Settings; warnanya ikut tema terang / gelap
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
    }
}

/// Potongan tata letak formulir: setiap baris = judul + keterangan di kiri, satu kontrol di kanan.
/// Pilihan nyala / mati selalu NSSwitch, aksi selalu tombol berlabel kata kerja → mudah dibedakan.
enum Form {
    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        return l
    }

    static func note(_ s: String, width: CGFloat = 380) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
        return l
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let v = NSStackView(views: views)
        v.orientation = vertical ? .vertical : .horizontal
        v.alignment = vertical ? .leading : .centerY
        v.spacing = spacing
        return v
    }

    static func row(_ title: String, _ detail: String?, _ control: NSView?) -> NSView {
        row(label(title, weight: .medium), detail, control)
    }

    static func row(_ head: NSView, _ detail: String?, _ control: NSView?) -> NSView {
        var texts: [NSView] = [head]
        if let detail { texts.append(note(detail, width: control == nil ? 540 : 380)) }
        let left = stack(texts, spacing: 3)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let r = stack([left], vertical: false, spacing: 16)
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            r.addArrangedSubview(control)
        }
        return r
    }

    static func section(_ title: String, _ rows: [NSView]) -> NSView {
        let card = CardView()
        let inner = stack([], spacing: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                inner.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            }
            inner.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        let out = stack([label(title, weight: .semibold), card], spacing: 6)
        card.widthAnchor.constraint(equalTo: out.widthAnchor).isActive = true
        return out
    }

    static func toggle(_ target: AnyObject, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        return s
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }
}

/// Halaman berukuran tetap berisi bagian-bagian formulir dari atas ke bawah
final class FormPage: NSViewController {
    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        view = v
        preferredContentSize = SettingsWindow.size
    }

    func set(_ sections: [NSView]) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let content = Form.stack([], spacing: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        for s in sections {
            content.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
}

/// Tab Clipboard: riwayat Mac dengan pencarian; centang clip lalu kirim ke server / HP
final class ClipboardPage: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var app: AppDelegate?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let info = NSTextField(labelWithString: "")
    private let hint = Form.note("", width: 590)
    private lazy var pendingButton = Form.button("Centang yang belum dikirim", self, #selector(checkPending))
    private lazy var sendButton = Form.button("Kirim yang dicentang", self, #selector(sendChecked))
    private lazy var copyButton = Form.button("Salin ke clipboard", self, #selector(copySelected))
    private lazy var deleteButton = Form.button("Hapus yang dicentang", self, #selector(deleteChecked))
    private var rows: [LocalClip] = []
    private var checked = Set<Int>()
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH.mm"
        return f
    }()
    private let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH.mm"
        return f
    }()

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        preferredContentSize = SettingsWindow.size

        search.placeholderString = "Cari clip…"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 260).isActive = true
        info.textColor = .secondaryLabelColor
        info.alignment = .right
        let top = Form.stack([search, info], vertical: false, spacing: 12)

        for (id, title, width) in [("check", "", 24), ("title", "Isi", 300), ("from", "Dari", 96), ("time", "Waktu", 78),
                                   ("status", "Status", 88)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = width
            if id == "check" { c.headerToolTip = "Centang clip yang ingin dikirim / dihapus" }
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        sendButton.bezelColor = .controlAccentColor // aksi utama; sengaja tanpa Enter (Enter dipakai kotak cari)
        let bottom = NSStackView()
        bottom.spacing = 8
        bottom.addView(pendingButton, in: .leading)
        bottom.addView(sendButton, in: .leading)
        bottom.addView(copyButton, in: .trailing)
        bottom.addView(deleteButton, in: .trailing)

        for x in [top, scroll, hint, bottom] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
            x.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20).isActive = true
            x.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20).isActive = true
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bottom.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            bottom.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
        ])
        view = v
        reload()
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    func reload() {
        guard isViewLoaded, let app else { return }
        let all = app.history.items
        rows = all.filter { $0.matches(search.stringValue) }
        checked.formIntersection(Set(all.map { $0.id }))
        table.reloadData()
        let pending = all.filter { $0.pending }.count
        info.stringValue = "\(all.count) dari maks \(app.historyLimit) clip · \(pending) belum dikirim"
        let remote = app.lanMode ? "HP (Wi-Fi lokal)" : "server & browser"
        hint.stringValue = app.syncActive
            ? "Centang clip lalu klik \"Kirim yang dicentang\" untuk mengirimnya ke \(remote). Klik dua kali sebuah clip untuk menyalinnya ke clipboard Mac."
            : "Autosync mati (atau belum login): nyalakan \"Autosync dengan \(remote)\" di menu PasteLAN atau tab Umum untuk mengirim clip. Klik dua kali sebuah clip untuk menyalinnya ke clipboard Mac."
        updateButtons()
    }

    private func updateButtons() {
        let n = checked.count
        sendButton.title = n > 0 ? "Kirim \(n) yang dicentang" : "Kirim yang dicentang"
        sendButton.isEnabled = n > 0 && (app?.syncActive ?? false)
        deleteButton.isEnabled = n > 0
        copyButton.isEnabled = table.selectedRow >= 0
        pendingButton.isEnabled = rows.contains { $0.pending && !checked.contains($0.id) }
    }

    func controlTextDidChange(_ n: Notification) { reload() }
    func tableViewSelectionDidChange(_ n: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let c = rows[row]
        switch tableColumn.identifier.rawValue {
        case "check":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
            b.state = checked.contains(c.id) ? .on : .off
            b.tag = c.id
            return b
        case "title": return cell(c.title, .labelColor, tip: c.text.map { String($0.prefix(600)) })
        case "from": return cell(c.source, .secondaryLabelColor)
        case "time": return cell(Calendar.current.isDateInToday(c.time) ? clock.string(from: c.time) : day.string(from: c.time),
                                 .secondaryLabelColor)
        default: return cell(c.status, c.pending ? .systemOrange : .secondaryLabelColor)
        }
    }

    private func cell(_ s: String, _ color: NSColor, tip: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = tip
        l.translatesAutoresizingMaskIntoConstraints = false
        let v = NSTableCellView()
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -2),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    @objc func toggleCheck(_ b: NSButton) {
        if b.state == .on { checked.insert(b.tag) } else { checked.remove(b.tag) }
        updateButtons()
    }

    @objc func checkPending() {
        for c in rows where c.pending { checked.insert(c.id) }
        table.reloadData()
        updateButtons()
    }

    @objc func sendChecked() {
        guard let app else { return }
        // daftar terbaru di depan → kirim dari yang terlama supaya urutan di server sama
        let list = rows.filter { checked.contains($0.id) }.reversed()
        let skipped = list.filter { !app.push($0) }.count
        checked.removeAll()
        reload()
        if skipped > 0 {
            let a = NSAlert()
            a.messageText = "\(skipped) clip tidak dikirim"
            a.informativeText = "Gambar yang berasal dari server belum diambil isinya (dan memang sudah ada di server)."
            a.runModal()
        }
    }

    @objc func copySelected() {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        app?.copyToClipboard(rows[r].id)
    }

    @objc func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        app?.copyToClipboard(rows[r].id)
    }

    @objc func deleteChecked() {
        let ids = checked
        checked.removeAll()
        app?.history.remove(ids)
    }
}

final class SettingsWindow: NSObject {
    enum Tab: Int { case general, connection, clipboard, about }
    static let size = NSSize(width: 640, height: 540)

    unowned let app: AppDelegate
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let general = FormPage()
    private let connection = FormPage()
    private let clips = ClipboardPage()
    private let about = FormPage()
    private var signature = ""
    private var pending = false

    // kontrol tab Umum (dibuat sekali, statusnya diperbarui di tempat supaya animasi NSSwitch tidak terputus)
    private lazy var syncTitle = Form.label("", weight: .medium)
    private lazy var syncSwitch = Form.toggle(self, #selector(syncChanged(_:)))
    private lazy var imagesSwitch = Form.toggle(self, #selector(saveImagesChanged(_:)))
    private lazy var loginSwitch = Form.toggle(self, #selector(loginChanged(_:)))
    private lazy var persistSwitch = Form.toggle(self, #selector(persistChanged(_:)))
    private lazy var limitPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for n in AppDelegate.historyLimits {
            p.addItem(withTitle: "\(n) clip")
            p.lastItem?.tag = n
        }
        p.target = self
        p.action = #selector(limitChanged(_:))
        return p
    }()

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    func show(_ tab: Tab) {
        if window == nil { build() }
        rebuild()
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if tab == .clipboard { clips.focusSearch() }
    }

    /// Status aplikasi berubah → perbarui isi jendela (digabung, dijalankan setelah aksi yang sedang berjalan selesai)
    func reload() {
        guard window != nil, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.rebuild()
        }
    }
    func reloadStatus() { reload() }
    func reloadClips() { if window != nil { clips.reload() } }

    private func build() {
        clips.app = app
        tabs.tabStyle = .toolbar
        let pages: [(NSViewController, String, String)] = [(general, "Umum", "gearshape"), (connection, "Koneksi", "network"),
                                                           (clips, "Clipboard", "list.bullet.rectangle"), (about, "Tentang", "info.circle")]
        for (vc, title, icon) in pages {
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.title = "Pengaturan PasteLAN"
        w.isReleasedWhenClosed = false
        w.setContentSize(SettingsWindow.size)
        w.center()
        window = w

        general.set([
            Form.section("Autosync", [
                Form.row(syncTitle, "Nyala = setiap copy di Mac otomatis terkirim dan kiriman dari HP otomatis masuk. " +
                         "Mati = clipboard manager offline biasa; semua copy tetap masuk riwayat, dan satu clip masih bisa " +
                         "dikirim dengan ⇧ + klik di menu (mode server). Saat dinyalakan lagi hanya copy baru yang dikirim; clip lama bisa " +
                         "dikirim dari tab Clipboard.", syncSwitch),
                Form.row("Simpan gambar dari HP ke Unduhan", "Selain masuk clipboard Mac, gambar yang diterima disimpan di folder Unduhan.",
                         imagesSwitch),
            ]),
            Form.section("Riwayat", [
                Form.row("Jumlah clip yang diingat", "Clip terlama dibuang saat batas tercapai.", limitPopup),
                Form.row("Simpan riwayat di Mac", "Riwayat tetap ada setelah PasteLAN / Mac di-restart (seperti CopyClip). " +
                         "Disimpan hanya di Mac ini (folder Application Support, hanya bisa dibaca akun Anda). " +
                         "Mati = hanya di memori, hilang saat PasteLAN ditutup.", persistSwitch),
            ]),
            Form.section("Sistem", [
                Form.row("Buka saat login", "PasteLAN otomatis berjalan setiap Mac dinyalakan.", loginSwitch),
            ]),
        ])
    }

    private func rebuild() {
        guard window != nil else { return }
        syncTitle.stringValue = app.lanMode ? "Autosync dengan HP (Wi-Fi lokal)" : "Autosync dengan server & browser"
        syncSwitch.state = app.sharing ? .on : .off
        imagesSwitch.state = app.d.bool(forKey: "saveImages") ? .on : .off
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        persistSwitch.state = app.historyPersist ? .on : .off
        if limitPopup.item(withTitle: "\(app.historyLimit) clip") == nil {
            limitPopup.addItem(withTitle: "\(app.historyLimit) clip")
            limitPopup.lastItem?.tag = app.historyLimit
        }
        limitPopup.selectItem(withTag: app.historyLimit)

        // Koneksi & Tentang dibangun ulang hanya kalau isinya berubah
        let flags: [Bool] = [app.lanMode, app.sharing, app.loggedIn, app.updater.hasUpdate, app.lan.shareURL != nil]
        let sig = flags.map { $0 ? "1" : "0" }.joined() + connectionLine + (app.serverURL?.absoluteString ?? "")
        if sig != signature {
            signature = sig
            connection.set(connectionSections())
            about.set(aboutSections())
        }
        clips.reload()
    }

    private var connected: Bool {
        app.lanMode ? app.sharing && app.lan.running && app.lan.shareURL != nil
                    : app.sharing && app.loggedIn && app.server.state == .connected
    }

    private var connectionLine: String {
        guard app.lanMode else { return app.statusText }
        let lan = app.lan
        if !app.sharing { return "Autosync mati · clipboard manager offline" }
        if lan.http.failed { return "Server Wi-Fi lokal gagal berjalan: port \(lan.port)–\(lan.port + 11) sibuk" }
        if !lan.running { return "Menyalakan server Wi-Fi lokal…" }
        if lan.shareURL == nil { return "Mac belum terhubung ke Wi-Fi / jaringan lokal" }
        let n = lan.connectedCount
        return n > 0 ? "Wi-Fi lokal aktif · \(n) HP terhubung" : "Wi-Fi lokal aktif · belum ada HP terhubung"
    }

    private func connectionSections() -> [NSView] {
        let server = NSButton(radioButtonWithTitle: "Server PasteLAN", target: self, action: #selector(useServer))
        server.state = app.lanMode ? .off : .on
        let lan = NSButton(radioButtonWithTitle: "Wi-Fi lokal", target: self, action: #selector(useLAN))
        lan.state = app.lanMode ? .on : .off
        let method = Form.section("Metode", [
            Form.row(server, "Lewat server PasteLAN milik Anda (internet, HTTPS). Halaman web-nya bisa dipasang sebagai aplikasi di HP.", nil),
            Form.row(lan, "Tanpa server: HP di Wi-Fi yang sama scan QR. Isi dienkripsi dengan kunci di QR.", nil),
        ])

        let dot = NSImageView(image: app.statusDot(connected))
        let line = Form.label(connectionLine)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [Form.stack([dot, line], vertical: false, spacing: 8)]
        if app.lanMode {
            let copy = Form.button("Salin link", app, #selector(AppDelegate.copyLink))
            copy.isEnabled = app.lan.shareURL != nil
            rows.append(Form.row("Tambah HP", "Menu PasteLAN → \"Tambah HP (scan QR)\", lalu scan QR dengan kamera HP.", copy))
            rows.append(Form.row("Reset link", "Kunci & link diganti: semua HP terputus dan harus scan QR baru.",
                                 Form.button("Reset link…", app, #selector(AppDelegate.resetLink))))
        } else if app.loggedIn, let url = app.serverURL {
            rows.append(Form.row("Server", url.host ?? url.absoluteString, Form.button("Ganti server…", app, #selector(AppDelegate.setupServer))))
            rows.append(Form.row("Tambah HP", "QR sekali pakai (5 menit): HP langsung masuk tanpa password.",
                                 Form.button("Tampilkan QR…", app, #selector(AppDelegate.pairPhone))))
            rows.append(Form.row("Halaman web PasteLAN", "Clipboard bersama di browser.",
                                 Form.button("Buka di browser", app, #selector(AppDelegate.openWeb))))
            rows.append(Form.row("Keluar dari server", "Token Mac ini dicabut di server.",
                                 Form.button("Keluar…", app, #selector(AppDelegate.logoutServer))))
        } else {
            rows.append(Form.row("Belum login", "Tempel link setup dari halaman admin server, atau isi alamat server + password perangkat.",
                                 Form.button("Atur server & login…", app, #selector(AppDelegate.setupServer))))
        }
        return [method, Form.section("Status", rows)]
    }

    private func aboutSections() -> [NSView] {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let head = Form.stack([icon, Form.stack([Form.label("PasteLAN", size: 15, weight: .semibold),
                                                 Form.note("Versi \(Updater.current) · copy-paste Mac ⇄ HP lewat server milik sendiri")],
                                                spacing: 2)],
                              vertical: false, spacing: 12)
        let up = app.updater
        let uninstall = Form.button("Uninstall…", app, #selector(AppDelegate.uninstall))
        uninstall.hasDestructiveAction = true
        return [
            head,
            Form.section("Pembaruan & bantuan", [
                Form.row("Pembaruan", up.hasUpdate ? "Versi \(up.latest?.version ?? "") tersedia." : "Dicek otomatis sehari sekali.",
                         Form.button(up.hasUpdate ? "Update…" : "Cek pembaruan…", up, #selector(Updater.checkNow))),
                Form.row("Cara pakai", "Panduan singkat untuk Mac, HP, dan Wi-Fi lokal.",
                         Form.button("Buka panduan…", app, #selector(AppDelegate.showHelp))),
            ]),
            Form.section("Hapus PasteLAN", [
                Form.row("Uninstall PasteLAN", "Keluar dari server, hapus pengaturan, lalu pindahkan PasteLAN.app ke Tong Sampah.", uninstall),
            ]),
        ]
    }

    @objc func syncChanged(_ s: NSSwitch) { if (s.state == .on) != app.sharing { app.toggleSharing() } }
    @objc func saveImagesChanged(_ s: NSSwitch) { app.d.set(s.state == .on, forKey: "saveImages") }
    @objc func persistChanged(_ s: NSSwitch) { app.setHistoryPersist(s.state == .on) }
    @objc func loginChanged(_ s: NSSwitch) {
        app.toggleLogin()
        reload()
    }
    @objc func limitChanged(_ p: NSPopUpButton) {
        app.setHistoryLimit(p.selectedTag())
        reload()
    }
    @objc func useServer() { app.setMode("server") }
    @objc func useLAN() { app.setMode("lan") }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon Dock
app.run()
