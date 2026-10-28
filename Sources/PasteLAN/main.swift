// PasteLAN — berbagi copy-paste (teks & gambar) antara Mac dan HP lewat server PasteLAN milik sendiri.
//   • Server kecil (folder server/, Go) di VPS Anda, lewat HTTPS; HP memakai halaman web / PWA dari server itu
//   • Mac login sekali dengan password server → token perangkat disimpan di Keychain
//   • HP → Mac : kirim teks / gambar dari HP → langsung masuk clipboard Mac
//   • Mac → HP : setiap copy di Mac muncul otomatis di HP, tinggal tekan "Salin"
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import CryptoKit
import ImageIO
import CoreImage
import Security
import SystemConfiguration
import ServiceManagement

// MARK: - Utilitas

func symbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "PasteLAN")
    img?.isTemplate = true // ikut tema terang/gelap menu bar
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

    /// Cuplikan satu baris untuk submenu Riwayat
    func title(me: String) -> String {
        let icon = device == me ? "💻" : "📱"
        if kind == "image" { return "\(icon)  🖼 Gambar \(fileExt(mime).uppercased()), \(byteString(size))" }
        var line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if line.count > 40 { line = String(line.prefix(40)) + "…" }
        return "\(icon)  \(line.isEmpty ? "(spasi kosong)" : line)"
    }
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
    var onIncoming: ((Clip) -> Void)?   // item baru dari perangkat lain
    var onChange: (() -> Void)?         // status / riwayat berubah
    var onUnauthorized: (() -> Void)?   // token dicabut / tidak berlaku lagi

    private let http: URLSession
    private var session = ""   // id session server: berubah saat server restart / riwayat dihapus
    private var after = 0
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
        let body = try? JSONSerialization.data(withJSONObject: ["password": password, "name": name])
        send(request("POST", "/api/login", body: body, type: "application/json")) { status, data, err in
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
        send(request("GET", "/api/items?after=\(after)&s=\(s)&wait=1")) { status, data, err in
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
        struct Reply: Decodable { let session: String; let you: String; let items: [Clip] }
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
            if primed, c.device != me { onIncoming?(c) }
        }
        primed = true
        if items.count > 20 { items.removeFirst(items.count - 20) }
        state = .connected
        onChange?()
    }

    // MARK: mengirim

    func sendText(_ s: String) { post("/api/text", Data(s.utf8), "text/plain; charset=utf-8") }
    func sendImage(_ d: Data) { post("/api/image", d, "application/octet-stream") } // jenis gambar dicek server dari isinya

    private func post(_ path: String, _ body: Data, _ type: String) {
        send(request("POST", path, body: body, type: type)) { status, _, _ in
            if status == 401 { self.unauthorized() }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let d = UserDefaults.standard
    let updater = Updater()
    let server = PasteServer()
    let clipboard = Clipboard()
    let macName = computerName()
    var flashTimer: Timer?

    var sharing: Bool { d.bool(forKey: "sharing") }
    var autoSend: Bool { d.bool(forKey: "autoSend") }
    var serverURL: URL? { d.string(forKey: "serverURL").flatMap(PasteServer.normalize) }
    var loggedIn: Bool { server.token != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: ["sharing": true, "autoSend": true, "saveImages": false])
        for k in ["key", "token", "port"] { d.removeObject(forKey: k) } // sisa mode Wi-Fi lokal (v0.x)

        item.autosaveName = "PasteLAN" // posisi ikon diingat
        item.button?.toolTip = "PasteLAN — copy-paste Mac ⇄ HP"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        server.configure(base: serverURL, token: Keychain.token)
        server.onChange = { [weak self] in self?.updateIcon() }
        server.onIncoming = { [weak self] c in self?.receive(c) }
        server.onUnauthorized = { [weak self] in self?.loginExpired() }
        clipboard.onChange = { [weak self] in self?.sendClipboard() }

        applySharing()
        updater.start()

        if !d.bool(forKey: "didOnboard") {
            d.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showHelp()
                self.askAutoSend()
                if !self.loggedIn { self.setupServer() }
            }
        } else if !loggedIn, !d.bool(forKey: "askedServer") {
            // update dari versi Wi-Fi lokal (v0.x): minta alamat server sekali
            d.set(true, forKey: "askedServer")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setupServer() }
        }
    }

    // MARK: berbagi

    func applySharing() {
        if sharing, loggedIn {
            if !server.running { server.start() }
            if autoSend { clipboard.startWatching() } else { clipboard.stopWatching() }
        } else {
            server.stop()
            clipboard.stopWatching()
        }
        updateIcon()
    }

    func updateIcon() {
        guard let b = item.button else { return }
        if flashTimer == nil { b.image = symbol("arrow.left.arrow.right.circle") }
        b.appearsDisabled = !sharing || server.state != .connected
    }

    /// Ikon ✓ sebentar saat menerima sesuatu dari HP
    func flash() {
        flashTimer?.invalidate()
        item.button?.image = symbol("checkmark.circle.fill")
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.flashTimer = nil
            self?.updateIcon()
        }
    }

    func sendClipboard() {
        guard sharing, loggedIn, let c = clipboard.read() else { return }
        if let text = c.text { server.sendText(text) }
        else if let data = c.data { server.sendImage(data) }
    }

    /// Item baru dari perangkat lain → langsung masuk clipboard Mac
    func receive(_ c: Clip) {
        if c.kind == "text", let text = c.text {
            clipboard.writeText(text)
            flash()
        } else if c.kind == "image" {
            server.image(c.id) { [weak self] data in
                guard let self, let data, self.clipboard.writeImage(data, mime: c.mime) else { return }
                if self.d.bool(forKey: "saveImages") { self.saveToDownloads(data, mime: c.mime) }
                self.flash()
            }
        }
    }

    /// Pertama kali dipakai: pengguna memilih sendiri apakah setiap copy di Mac langsung tersedia untuk HP
    func askAutoSend() {
        let a = NSAlert()
        a.messageText = "Kirim setiap copy di Mac ke HP secara otomatis?"
        a.informativeText = "Kalau ya, semua yang Anda copy (⌘C) di Mac langsung muncul di HP yang login ke server PasteLAN. " +
            "Kalau tidak, kirim manual lewat menu \"Kirim clipboard Mac sekarang\". Bisa diubah kapan saja di menu."
        a.addButton(withTitle: "Ya, otomatis")
        a.addButton(withTitle: "Manual saja")
        NSApp.activate(ignoringOtherApps: true)
        d.set(a.runModal() == .alertFirstButtonReturn, forKey: "autoSend")
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

    /// Minta alamat server + password, lalu login (password tidak disimpan; token disimpan di Keychain)
    @objc func setupServer() {
        let a = NSAlert()
        a.messageText = "Server PasteLAN"
        a.informativeText = "Masukkan alamat server PasteLAN Anda dan password-nya. Password hanya dipakai sekali " +
            "untuk login; Mac ini lalu menyimpan token perangkat di Keychain."
        let urlField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        urlField.placeholderString = "pastelan.example.com"
        urlField.stringValue = d.string(forKey: "serverURL") ?? ""
        let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        pwField.placeholderString = "Password server"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        box.addSubview(urlField)
        box.addSubview(pwField)
        a.accessoryView = box
        a.addButton(withTitle: "Login")
        a.addButton(withTitle: "Batal")
        a.window.initialFirstResponder = urlField.stringValue.isEmpty ? urlField : pwField
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let url = PasteServer.normalize(urlField.stringValue) else {
            return showError("Alamat server tidak valid", "Pakai alamat HTTPS server PasteLAN, mis. pastelan.example.com.")
        }
        let password = pwField.stringValue
        let doLogin = { [weak self] in
            guard let self else { return }
            self.server.login(base: url, password: password, name: self.macName) { token, err in
                guard let token else { return self.showError("Login gagal", err ?? "Tidak diketahui") }
                Keychain.token = token
                self.d.set(url.absoluteString, forKey: "serverURL")
                self.applySharing()
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
        clipboard.stopWatching()
        updateIcon()
        showError("Login PasteLAN berakhir", "Mac ini dikeluarkan dari server PasteLAN (perangkat dicabut atau server diganti). Login lagi?")
    }

    @objc func logoutServer() {
        let a = NSAlert()
        a.messageText = "Keluar dari server PasteLAN?"
        a.informativeText = "Token Mac ini dicabut di server. Untuk tersambung lagi perlu password server."
        a.addButton(withTitle: "Keluar")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        server.logout {}
        Keychain.token = nil
        applySharing()
    }

    @objc func openWeb() {
        if let url = serverURL { NSWorkspace.shared.open(url) }
    }

    // MARK: menu (dibangun ulang setiap dibuka → status & riwayat selalu terbaru)

    var statusText: String {
        let host = serverURL?.host ?? "server"
        guard loggedIn else { return "Belum login ke server PasteLAN" }
        guard sharing else { return "Berbagi dimatikan" }
        switch server.state {
        case .loggedOut: return "Belum login ke server PasteLAN"
        case .connecting: return "Menghubungkan ke \(host)…"
        case .connected: return "Terhubung ke \(host)"
        case .offline(let e): return "Tidak bisa menghubungi \(host): \(e.count > 50 ? String(e.prefix(50)) + "…" : e)"
        }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: "PasteLAN", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        add("Berbagi aktif", #selector(toggleSharing), on: sharing)

        menu.addItem(.separator())
        let st = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        if loggedIn, let url = serverURL {
            // alamat server saja (tanpa rahasia): HP membukanya lalu login dengan password & install sebagai aplikasi
            let qr = NSMenuItem()
            qr.view = qrView(url: url.absoluteString, info: "Scan dengan kamera HP, login, lalu \"Install\" / \"Tambahkan ke Layar Utama\"")
            menu.addItem(qr)
            add("Buka PasteLAN di browser (kelola perangkat)", #selector(openWeb))
            add("Ganti server…", #selector(setupServer))
            add("Keluar dari server…", #selector(logoutServer))
        } else {
            add("Atur server & login…", #selector(setupServer))
        }

        menu.addItem(.separator())
        let hist = NSMenuItem(title: "Riwayat", action: nil, keyEquivalent: "")
        let hm = NSMenu()
        hm.autoenablesItems = false
        if server.items.isEmpty {
            let e = NSMenuItem(title: "Belum ada", action: nil, keyEquivalent: "")
            e.isEnabled = false
            hm.addItem(e)
        } else {
            for c in server.items.reversed() {
                let it = NSMenuItem(title: c.title(me: server.me), action: #selector(recopy(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.toolTip = "Klik untuk menyalin lagi ke clipboard Mac"
                hm.addItem(it)
            }
            hm.addItem(.separator())
            let cl = NSMenuItem(title: "Hapus riwayat (semua perangkat)", action: #selector(clearHistory), keyEquivalent: "")
            cl.target = self
            hm.addItem(cl)
        }
        hist.submenu = hm
        menu.addItem(hist)
        add("Kirim clipboard Mac otomatis", #selector(toggleAutoSend), on: autoSend)
        add("Kirim clipboard Mac sekarang", #selector(sendNow), enabled: sharing && loggedIn)
        add("Simpan juga gambar dari HP ke Unduhan", #selector(toggleSaveImages), on: d.bool(forKey: "saveImages"))

        menu.addItem(.separator())
        add("Buka saat login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add("Cara pakai…", #selector(showHelp))
        menu.addItem(updater.menuItem)
        add("Uninstall PasteLAN…", #selector(uninstall))
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @discardableResult
    func add(_ title: String, _ action: Selector, on: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled
        if let on { it.state = on ? .on : .off }
        menu.addItem(it)
        return it
    }

    /// QR code + alamat, ditampilkan langsung di dalam menu
    func qrView(url: String, info: String) -> NSView {
        let w: CGFloat = 260, qr: CGFloat = 190
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: qr + 62))

        let label = NSTextField(wrappingLabelWithString: info)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 14, y: 6, width: w - 28, height: 32)
        v.addSubview(label)

        let addr = NSTextField(labelWithString: url.replacingOccurrences(of: "https://", with: ""))
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

    @objc func toggleSharing() {
        d.set(!sharing, forKey: "sharing")
        applySharing()
    }
    @objc func toggleAutoSend() {
        d.set(!autoSend, forKey: "autoSend")
        applySharing()
    }
    @objc func toggleSaveImages() {
        d.set(!d.bool(forKey: "saveImages"), forKey: "saveImages")
    }
    @objc func sendNow() {
        guard clipboard.read() != nil else {
            let a = NSAlert()
            a.messageText = "Clipboard Mac kosong atau tidak didukung"
            a.informativeText = "PasteLAN mengirim teks dan gambar. Isi dari password manager sengaja tidak dikirim."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        sendClipboard()
    }
    @objc func recopy(_ s: NSMenuItem) {
        guard let id = s.representedObject as? Int, let c = server.items.first(where: { $0.id == id }) else { return }
        if let text = c.text { clipboard.writeText(text) }
        else if c.kind == "image" {
            server.image(id) { [weak self] data in
                if let data { _ = self?.clipboard.writeImage(data, mime: c.mime) }
            }
        }
    }
    @objc func clearHistory() {
        server.clearHistory() // semua perangkat menerima session baru → daftarnya dikosongkan
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

        1. Klik ikon ⇄ di menu bar → "Atur server & login…", isi alamat server dan password-nya.
        2. Scan QR code di menu dengan kamera HP, login dengan password yang sama, lalu pilih \
        "Install" / "Tambahkan ke Layar Utama" supaya PasteLAN jadi aplikasi di HP.
        3. HP → Mac: tempel teks atau pilih gambar, tekan "Kirim", lalu ⌘V di Mac.
        4. Mac → HP: copy apa saja di Mac (⌘C), isinya muncul di HP. Tekan "Salin".

        Keamanan: semua lewat HTTPS. Isi clipboard hanya disimpan di memori server (maks 20 item, \
        hilang setelah 24 jam / saat server restart). Isi dari password manager tidak pernah dikirim. \
        Perangkat yang hilang bisa dicabut dari halaman PasteLAN → Pengaturan.
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

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon Dock
app.run()
