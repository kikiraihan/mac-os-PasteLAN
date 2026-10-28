// PasteLAN — berbagi copy-paste (teks & gambar) antara Mac dan HP lewat Wi-Fi yang sama.
//   • Mac menjalankan server HTTP kecil di jaringan lokal (tanpa cloud, tanpa akun)
//   • HP cukup scan QR code di menu bar → halaman web terbuka di browser (tanpa install aplikasi)
//   • HP → Mac : tempel teks / pilih gambar di halaman, tekan kirim → langsung masuk clipboard Mac
//   • Mac → HP : setiap copy di Mac muncul otomatis di halaman HP, tinggal tekan "Salin"
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import ImageIO
import Network
import CoreImage
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

/// Bandingkan token tanpa bocor lewat waktu eksekusi
func sameToken(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

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

// MARK: - Riwayat clipboard (hanya di memori, tidak pernah ditulis ke disk)

struct Clip {
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

    /// Cuplikan satu baris untuk submenu Riwayat
    var title: String {
        let icon = from == "mac" ? "💻" : "📱"
        if kind == "image" { return "\(icon)  🖼 Gambar \(fileExt(mime).uppercased()), \(byteString(size))" }
        var line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if line.count > 40 { line = String(line.prefix(40)) + "…" }
        return "\(icon)  \(line.isEmpty ? "(spasi kosong)" : line)"
    }
}

final class ClipStore {
    private(set) var items: [Clip] = [] // terlama di depan, terbaru di belakang
    private(set) var session = randomHex(8) // berubah saat riwayat dihapus → HP mengosongkan daftarnya
    private var nextID = 1
    let maxItems = 20
    let maxImageBytes = 150 * 1024 * 1024
    var onAdd: ((Clip) -> Void)?

    @discardableResult
    func add(kind: String, from: String, text: String? = nil, data: Data? = nil, mime: String? = nil) -> Clip {
        // copy isi yang sama dua kali berturut-turut → tidak perlu item baru
        if let last = items.last, last.from == from, last.kind == kind, last.text == text, last.data == data { return last }
        let c = Clip(id: nextID, kind: kind, from: from, text: text, data: data, mime: mime, time: Date())
        nextID += 1
        items.append(c)
        while items.count > maxItems { items.removeFirst() }
        while items.count > 1, items.reduce(0, { $0 + ($1.data?.count ?? 0) }) > maxImageBytes { items.removeFirst() }
        onAdd?(c)
        return c
    }

    func after(_ id: Int) -> [Clip] { items.filter { $0.id > id } }
    func clip(_ id: Int) -> Clip? { items.first { $0.id == id } }

    func clear() {
        items.removeAll()
        session = randomHex(8)
    }
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

// MARK: - Server HTTP mini (Network.framework, tanpa dependensi)

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // nama header huruf kecil
    let body: Data
}

final class HTTPConnection {
    private let conn: NWConnection
    private let maxBody: Int
    private var buffer = Data()
    private var parsed = false
    private var headerOK = false // header lengkap & lolos cek token/batas body
    private var responded = false
    private(set) var closed = false
    let host: String // IP pengirim (tanpa port), untuk membatasi koneksi per perangkat
    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    var onClose: (() -> Void)?
    /// Dipanggil begitu header lengkap, SEBELUM body dibaca: batas body, atau nil = tolak (403).
    /// Supaya perangkat tanpa token tidak bisa memenuhi memori dengan body besar.
    var bodyLimit: (_ method: String, _ path: String, _ query: [String: String], _ headers: [String: String]) -> Int? = { _, _, _, _ in nil }

    static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          411: "Length Required", 413: "Payload Too Large", 415: "Unsupported Media Type",
                          431: "Request Header Fields Too Large", 500: "Internal Server Error"]

    init(_ c: NWConnection, maxBody: Int) {
        conn = c
        self.maxBody = maxBody
        if case let .hostPort(h, _) = c.endpoint { host = "\(h)" } else { host = "\(c.endpoint)" }
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
        // token & batas body dicek sebelum body ditunggu / disimpan di memori
        guard let allowed = bodyLimit(method, path, query, headers) else {
            respond(403, type: "application/json; charset=utf-8", body: json(["error": "token"])); return true
        }
        let limit = min(allowed, maxBody)
        guard length <= limit else { respond(413, text: "Terlalu besar (maks \(byteString(limit)))"); return true }
        headerOK = true
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return false }

        let body = buffer.subdata(in: bodyStart..<bodyStart + length)
        parsed = true
        buffer = Data()
        onRequest?(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body), self)
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
    var handler: ((HTTPRequest, HTTPConnection) -> Void)?
    var bodyLimit: (_ method: String, _ path: String, _ query: [String: String], _ headers: [String: String]) -> Int? = { _, _, _, _ in nil }
    var onChange: (() -> Void)?

    let maxBody = 30 * 1024 * 1024
    let maxConnections = 64
    let maxPerHost = 8 // satu halaman HP butuh 1 long-poll + beberapa request kirim / gambar

    var running: Bool { port != nil }

    /// Buka port `first`; kalau sibuk dipakai aplikasi lain, coba port berikutnya
    func start(from first: UInt16, tries: Int = 12) {
        stop()
        failed = false
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
        guard HTTPServer.isLocalPeer(nc.endpoint), conns.count < maxConnections else { return nc.cancel() }
        let c = HTTPConnection(nc, maxBody: maxBody)
        guard conns.values.filter({ $0.host == c.host }).count < maxPerHost else { return nc.cancel() }
        let key = ObjectIdentifier(c)
        conns[key] = c
        c.bodyLimit = { [weak self] m, p, q, h in self?.bodyLimit(m, p, q, h) }
        c.onRequest = { [weak self] req, c in self?.handler?(req, c) }
        c.onClose = { [weak self] in self?.conns[key] = nil }
        c.start()
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

// MARK: - Update (cek rilis terbaru di GitHub Releases)

final class Updater: NSObject {
    let repo = "kikiraihan/mac-os-PasteLAN"
    let appName = "PasteLAN"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    var latest: (version: String, zip: URL?, page: URL)?
    var timer: Timer?

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
            var info: (String, URL?, URL)?
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String,
               let page = (j["html_url"] as? String).flatMap({ URL(string: $0) }) {
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String) == "\(self.appName).zip" }?["browser_download_url"] as? String
                info = (tag, zip.flatMap { URL(string: $0) }, page)
            }
            DispatchQueue.main.async {
                if let info { self.latest = (info.0, info.1, info.2) }
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
    func install(_ l: (version: String, zip: URL?, page: URL)) {
        let dest = Bundle.main.bundleURL
        // tanpa file .zip, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
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
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                        problem = "File rilis tidak berisi \(self.appName).app."
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
    let server = HTTPServer()
    let store = ClipStore()
    let clipboard = Clipboard()
    let macName = computerName()

    var token = ""
    var waiters: [(c: HTTPConnection, after: Int)] = [] // long-poll yang sedang ditahan
    var flashTimer: Timer?

    var sharing: Bool { d.bool(forKey: "sharing") }
    var autoSend: Bool { d.bool(forKey: "autoSend") }

    /// Link yang di-scan HP (nil kalau Mac tidak terhubung ke jaringan lokal / server belum jalan)
    var shareURL: String? {
        guard let port = server.port, let ip = localIPv4() else { return nil }
        return "http://\(ip):\(port)/?t=\(token)"
    }

    /// Perkiraan jumlah HP yang sedang membuka halaman (tiap halaman menahan satu long-poll)
    var connectedCount: Int { waiters.filter { $0.c.isWaiting }.count }

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: ["sharing": true, "autoSend": true, "saveImages": false, "port": 8787])
        if let t = d.string(forKey: "token"), t.count == 32 { token = t } else { resetToken() }

        item.autosaveName = "PasteLAN" // posisi ikon diingat
        item.button?.toolTip = "PasteLAN — copy-paste Mac ⇄ HP lewat Wi-Fi"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        server.handler = { [weak self] r, c in self?.handle(r, c) }
        server.bodyLimit = { [weak self] m, p, q, h in self?.bodyLimit(m, p, q, h) }
        server.onChange = { [weak self] in self?.updateIcon() }
        store.onAdd = { [weak self] _ in self?.wakeWaiters() }
        clipboard.onChange = { [weak self] in self?.sendClipboard() }

        applySharing()
        updater.start()

        if !d.bool(forKey: "didOnboard") {
            d.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showHelp()
                self.askAutoSend()
            }
        }
    }

    // MARK: berbagi

    func applySharing() {
        if sharing {
            if !server.running { server.start(from: UInt16(clamping: d.integer(forKey: "port"))) }
            if autoSend { clipboard.startWatching() } else { clipboard.stopWatching() }
        } else {
            waiters.removeAll()
            server.stop()
            clipboard.stopWatching()
        }
        updateIcon()
    }

    func updateIcon() {
        guard let b = item.button else { return }
        if flashTimer == nil { b.image = symbol("arrow.left.arrow.right.circle") }
        b.appearsDisabled = !sharing || !server.running
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
        guard let c = clipboard.read() else { return }
        store.add(kind: c.kind, from: "mac", text: c.text, data: c.data, mime: c.mime)
    }

    /// Item baru / riwayat dihapus → jawab semua HP yang sedang menunggu (long-poll)
    func wakeWaiters() {
        let list = waiters
        waiters.removeAll()
        for w in list { answerItems(w.c, after: w.after) }
    }

    func resetToken() {
        token = randomHex()
        d.set(token, forKey: "token")
    }

    /// Pertama kali dipakai: pengguna memilih sendiri apakah setiap copy di Mac langsung tersedia untuk HP
    func askAutoSend() {
        let a = NSAlert()
        a.messageText = "Kirim setiap copy di Mac ke HP secara otomatis?"
        a.informativeText = "Kalau ya, semua yang Anda copy (⌘C) di Mac langsung muncul di halaman HP yang terhubung. " +
            "Kalau tidak, kirim manual lewat menu \"Kirim clipboard Mac sekarang\". Bisa diubah kapan saja di menu."
        a.addButton(withTitle: "Ya, otomatis")
        a.addButton(withTitle: "Manual saja")
        NSApp.activate(ignoringOtherApps: true)
        d.set(a.runModal() == .alertFirstButtonReturn, forKey: "autoSend")
        applySharing()
    }

    // MARK: HTTP

    /// Dicek begitu header request lengkap (sebelum body dibaca): batas body, atau nil = token salah (403)
    func bodyLimit(_ method: String, _ path: String, _ query: [String: String], _ headers: [String: String]) -> Int? {
        guard path.hasPrefix("/api/") else { return 0 } // halaman HTML: token dicek di handle(), tanpa body
        guard sameToken(headers["x-token"] ?? query["t"], token) else { return nil }
        switch (method, path) {
        case ("POST", "/api/text"): return clipboard.maxText
        case ("POST", "/api/image"): return clipboard.maxImage
        default: return 0
        }
    }

    func handle(_ r: HTTPRequest, _ c: HTTPConnection) {
        if r.path == "/" || r.path == "/index.html" {
            guard sameToken(r.query["t"], token) else {
                return c.respond(403, type: "text/html; charset=utf-8", body: Data(Page.expired.utf8))
            }
            return c.respond(200, type: "text/html; charset=utf-8", body: Data(Page.html.utf8))
        }
        guard r.path.hasPrefix("/api/") else { return c.respond(404, text: "Tidak ditemukan") }
        guard sameToken(r.headers["x-token"] ?? r.query["t"], token) else {
            return c.respondJSON(["error": "token"], status: 403)
        }

        switch (r.method, r.path) {
        case ("GET", "/api/items"):
            // session beda (Mac baru dibuka / riwayat dihapus) → kirim ulang semua item
            let fresh = r.query["s"] != store.session
            let after = fresh ? 0 : Int(r.query["after"] ?? "") ?? 0
            if !fresh, r.query["wait"] == "1", store.after(after).isEmpty {
                waiters.append((c, after))
                // tidak ada item baru dalam 25 detik → jawab kosong, halaman langsung bertanya lagi
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self, weak c] in
                    guard let self, let c, let i = self.waiters.firstIndex(where: { $0.c === c }) else { return }
                    self.waiters.remove(at: i)
                    self.answerItems(c, after: after)
                }
                return
            }
            answerItems(c, after: after)

        case ("POST", "/api/text"):
            guard let text = String(data: r.body, encoding: .utf8), !text.isEmpty else {
                return c.respondJSON(["error": "Teks kosong"], status: 400)
            }
            clipboard.writeText(text)
            let clip = store.add(kind: "text", from: "phone", text: text)
            flash()
            c.respondJSON(["ok": true, "id": clip.id])

        case ("POST", "/api/image"):
            var mime = (r.headers["content-type"] ?? "").split(separator: ";").first.map(String.init) ?? ""
            if mime == "image/jpg" { mime = "image/jpeg" }
            guard !r.body.isEmpty, clipboard.writeImage(r.body, mime: mime) else {
                return c.respondJSON(["error": "Bukan gambar yang didukung"], status: 415)
            }
            // MIME dari HP disajikan ulang sebagai Content-Type → hanya format gambar biasa (bukan image/svg+xml dll.)
            let clip = store.add(kind: "image", from: "phone", data: r.body, mime: Clipboard.imageMimes.contains(mime) ? mime : "image/png")
            if d.bool(forKey: "saveImages") { saveToDownloads(r.body, mime: clip.mime) }
            flash()
            c.respondJSON(["ok": true, "id": clip.id])

        case ("GET", let p) where p.hasPrefix("/api/image/"):
            guard let id = Int(p.dropFirst("/api/image/".count)), let clip = store.clip(id), let data = clip.data else {
                return c.respond(404, text: "Gambar tidak ada lagi di riwayat")
            }
            // URL berisi session (?s=) → id yang sama setelah Mac restart tetap beda URL, aman di-cache
            c.respond(200, type: clip.mime ?? "image/png", body: data,
                      headers: ["Cache-Control": "private, max-age=86400",
                                "Content-Disposition": "inline; filename=\"pastelan-\(id).\(fileExt(clip.mime))\""])

        default:
            c.respond(404, text: "Tidak ditemukan")
        }
    }

    func answerItems(_ c: HTTPConnection, after: Int) {
        c.respondJSON(["session": store.session, "name": macName, "items": store.after(after).map { $0.info }])
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

    // MARK: menu (dibangun ulang setiap dibuka → IP, QR & riwayat selalu terbaru)

    func menuNeedsUpdate(_ m: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: "PasteLAN", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        add("Berbagi aktif", #selector(toggleSharing), on: sharing)

        if sharing {
            menu.addItem(.separator())
            let url = shareURL
            let info: String
            if server.failed { info = "Server gagal berjalan: port \(d.integer(forKey: "port"))–\(d.integer(forKey: "port") + 11) sibuk." }
            else if !server.running { info = "Menyalakan server…" }
            else if url == nil { info = "Mac belum terhubung ke Wi-Fi / jaringan lokal." }
            else { info = "Scan dengan kamera HP (Wi-Fi yang sama)" }
            let qr = NSMenuItem()
            qr.view = qrView(url: url, info: info)
            menu.addItem(qr)
            if url != nil {
                add("Salin link", #selector(copyLink))
                let n = connectedCount
                let st = NSMenuItem(title: n > 0 ? "📱 \(n) perangkat terhubung" : "Belum ada perangkat terhubung", action: nil, keyEquivalent: "")
                st.isEnabled = false
                menu.addItem(st)
            }
        }

        menu.addItem(.separator())
        let hist = NSMenuItem(title: "Riwayat", action: nil, keyEquivalent: "")
        let hm = NSMenu()
        hm.autoenablesItems = false
        if store.items.isEmpty {
            let e = NSMenuItem(title: "Belum ada", action: nil, keyEquivalent: "")
            e.isEnabled = false
            hm.addItem(e)
        } else {
            for c in store.items.reversed() {
                let it = NSMenuItem(title: c.title, action: #selector(recopy(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.toolTip = "Klik untuk menyalin lagi ke clipboard Mac"
                hm.addItem(it)
            }
            hm.addItem(.separator())
            let cl = NSMenuItem(title: "Hapus riwayat", action: #selector(clearHistory), keyEquivalent: "")
            cl.target = self
            hm.addItem(cl)
        }
        hist.submenu = hm
        menu.addItem(hist)
        add("Kirim clipboard Mac otomatis", #selector(toggleAutoSend), on: autoSend)
        add("Kirim clipboard Mac sekarang", #selector(sendNow), enabled: sharing)
        add("Simpan juga gambar dari HP ke Unduhan", #selector(toggleSaveImages), on: d.bool(forKey: "saveImages"))

        menu.addItem(.separator())
        add("Ganti link (putuskan semua HP)…", #selector(regenerateToken))
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

        if let url {
            let addr = NSTextField(labelWithString: url.components(separatedBy: "/?").first ?? url)
            addr.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            addr.alignment = .center
            addr.frame = NSRect(x: 14, y: 36, width: w - 28, height: 18)
            v.addSubview(addr)

            let iv = NSImageView(frame: NSRect(x: (w - qr) / 2, y: 58, width: qr, height: qr))
            iv.image = qrImage(url, points: qr)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor.white.cgColor // QR selalu di atas putih supaya terbaca kamera
            iv.layer?.cornerRadius = 6
            v.addSubview(iv)
        }
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
    @objc func copyLink() {
        guard let url = shareURL else { return }
        // link berisi token → jangan ikut Universal Clipboard (perangkat Apple lain) & tandai rahasia untuk clipboard manager
        let pb = clipboard.pb
        _ = pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(url, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        clipboard.markOwnWrite()
    }
    @objc func recopy(_ s: NSMenuItem) {
        guard let id = s.representedObject as? Int, let c = store.clip(id) else { return }
        if let text = c.text { clipboard.writeText(text) }
        else if let data = c.data { _ = clipboard.writeImage(data, mime: c.mime) }
    }
    @objc func clearHistory() {
        store.clear()
        // HP yang sedang menunggu langsung diberi session baru → daftarnya dikosongkan
        wakeWaiters()
    }
    @objc func regenerateToken() {
        let a = NSAlert()
        a.messageText = "Ganti link PasteLAN?"
        a.informativeText = "Semua HP yang terhubung akan terputus dan harus scan QR code yang baru."
        a.addButton(withTitle: "Ganti link")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        resetToken()
        let list = waiters
        waiters.removeAll()
        for w in list { w.c.respondJSON(["error": "token"], status: 403) }
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
        PasteLAN memindahkan teks & gambar antara Mac dan HP lewat Wi-Fi yang sama. \
        Tanpa cloud, tanpa akun, tanpa install aplikasi di HP.

        1. Pastikan Mac dan HP tersambung ke Wi-Fi yang sama (atau Mac memakai hotspot HP).
        2. Klik ikon ⇄ di menu bar, lalu scan QR code dengan kamera HP. Halaman PasteLAN terbuka di browser. \
        Simpan sebagai bookmark / "Tambahkan ke Layar Utama" supaya tidak perlu scan lagi.
        3. HP → Mac: tempel teks atau pilih gambar, tekan "Kirim ke Mac", lalu ⌘V di Mac.
        4. Mac → HP: copy apa saja di Mac (⌘C), isinya muncul di halaman HP. Tekan "Salin", \
        atau tekan lama gambar untuk menyalin / menyimpan.

        Kalau macOS bertanya "Izinkan PasteLAN menerima koneksi masuk?", pilih Izinkan.
        Wi-Fi kantor / kampus / publik sering memblokir antar-perangkat. Kalau HP tidak bisa membuka \
        halaman, pakai Wi-Fi rumah atau hotspot HP.

        Privasi: riwayat hanya disimpan di memori (hilang saat PasteLAN ditutup). Isi dari \
        password manager tidak pernah dikirim. "Ganti link" memutus semua HP yang pernah terhubung.
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Hapus PasteLAN dari Mac: login item, pengaturan, lalu .app dipindahkan ke Tong Sampah
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall PasteLAN?"
        a.informativeText = "PasteLAN dihapus dari 'Buka saat login', pengaturannya dihapus, lalu PasteLAN.app dipindahkan ke Tong Sampah dan aplikasi ditutup. Semua link HP otomatis tidak berlaku."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        server.stop()
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

// MARK: - Halaman web untuk HP (ditanam di aplikasi, tanpa file / CDN eksternal)

enum Page {
    static let expired = #"""
    <!doctype html><html lang="id"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>PasteLAN</title>
    <style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;text-align:center;color:#1d1d1f;background:#f5f5f7}
    @media (prefers-color-scheme:dark){body{color:#f5f5f7;background:#000}}</style></head>
    <body><h2>Link tidak berlaku</h2><p>Klik ikon ⇄ PasteLAN di menu bar Mac, lalu scan ulang QR code-nya.</p></body></html>
    """#

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
      <div id="list"></div>
    </main>
    <div id="toast"></div>
    <script>
    (() => {
      const token = new URLSearchParams(location.search).get('t') || '';
      const $ = id => document.getElementById(id);
      const MAX_ITEMS = 20, MAX_BYTES = 30 * 1024 * 1024;
      let after = 0, session = '', stopped = false, ctrl = null;

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
      }
      function expired() {
        stopped = true;
        setStatus('off', 'Link tidak berlaku');
        $('list').innerHTML = '<div class="card empty">Link ini sudah tidak berlaku. Klik ikon ⇄ PasteLAN di menu bar Mac, lalu scan ulang QR code-nya.</div>';
      }

      async function api(path, opts = {}) {
        opts.headers = Object.assign({ 'X-Token': token }, opts.headers || {});
        const r = await fetch(path, opts);
        if (r.status === 403) { expired(); throw new Error('403'); }
        const j = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(j.error || ('HTTP ' + r.status));
        return j;
      }

      // ---------- menerima dari Mac (long-poll) ----------
      async function poll() {
        while (!stopped) {
          ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), 35000);
          try {
            const j = await api(`/api/items?after=${after}&s=${encodeURIComponent(session)}&wait=1`, { signal: ctrl.signal });
            if (j.session !== session) { session = j.session; after = 0; $('list').textContent = ''; }
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
          const src = `/api/image/${it.id}?s=${encodeURIComponent(session)}&t=${encodeURIComponent(token)}`;
          const img = el('img');
          img.src = src;
          img.alt = 'Gambar';
          card.append(img);
          const a = el('a', 'btn grow', 'Simpan / buka');
          a.href = src;
          a.download = `pastelan-${it.id}.${(it.mime || 'image/png').split('/')[1].replace('jpeg', 'jpg')}`;
          a.target = '_blank';
          row.append(a);
        }
        card.append(row);
        if (it.kind !== 'text') card.append(el('div', 'hint', 'Tekan lama gambar untuk menyalin atau menyimpan.'));
        list.prepend(card);
        while (list.children.length > MAX_ITEMS) list.lastChild.remove();
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
          await api('/api/text', { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: text });
          $('input').value = '';
          toast('Terkirim ke clipboard Mac ✓');
        } catch (e) { if (!stopped) toast('Gagal mengirim: ' + e.message); }
        finally { $('send').disabled = false; }
      }
      async function sendImage(file) {
        if (file.size > MAX_BYTES) return toast('Gambar terlalu besar (maks 30 MB)');
        toast('Mengirim gambar…');
        try {
          await api('/api/image', { method: 'POST', headers: { 'Content-Type': file.type || 'application/octet-stream' }, body: file });
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

      if (!token) expired(); else { showEmpty(); poll(); }
    })();
    </script>
    </body>
    </html>
    """#
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon Dock
app.run()
