// Tanda tangan Ed25519 untuk file rilis PasteLAN.zip (dicek oleh auto-update di aplikasi sebelum dipasang).
//
//   swift scripts/sign-release.swift keygen [file]          → buat kunci (sekali saja, di Mac Anda sendiri)
//   swift scripts/sign-release.swift sign <zip> <tag>        → cetak tanda tangan (base64) ke stdout
//   swift scripts/sign-release.swift verify <zip> <tag> <sig-file> <public-key>
//
// Kunci privat dibaca dari env PASTELAN_SIGNING_KEY, atau dari file ~/.pastelan-signing-key.
// Yang ditandatangani: "PasteLAN <tag>\n" + isi zip → zip versi lama tidak bisa dipakai untuk tag baru.
import CryptoKit
import Foundation

let defaultKeyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pastelan-signing-key").path

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func message(zip: String, tag: String) -> Data {
    guard let data = FileManager.default.contents(atPath: zip) else { die("Tidak bisa membaca \(zip)") }
    return Data("PasteLAN \(tag)\n".utf8) + data
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "keygen":
    let file = args.count > 2 ? args[2] : defaultKeyFile
    guard !FileManager.default.fileExists(atPath: file) else { die("\(file) sudah ada — tidak ditimpa.") }
    let key = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: file, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                            attributes: [.posixPermissions: 0o600])
    guard ok else { die("Gagal menulis \(file)") }
    print("Kunci privat disimpan di: \(file)  (RAHASIA — jangan dibagikan / di-commit)")
    print("")
    print("Kunci publik (aman dibagikan, ditanam di aplikasi → Updater.publicKey):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign" where args.count == 4:
    let text = ProcessInfo.processInfo.environment["PASTELAN_SIGNING_KEY"]
        ?? (try? String(contentsOfFile: defaultKeyFile, encoding: .utf8))
    guard let text, let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        die("Kunci privat tidak ada / tidak valid (PASTELAN_SIGNING_KEY atau \(defaultKeyFile)).")
    }
    guard let sig = try? key.signature(for: message(zip: args[2], tag: args[3])) else { die("Gagal menandatangani") }
    print(sig.base64EncodedString())

case "verify" where args.count == 6:
    guard let sigText = try? String(contentsOfFile: args[4], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = Data(base64Encoded: args[5]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { die("Tanda tangan / kunci publik tidak valid") }
    guard key.isValidSignature(sig, for: message(zip: args[2], tag: args[3])) else { die("❌ Tanda tangan TIDAK cocok") }
    print("✅ Tanda tangan cocok")

default:
    die("Pakai: keygen [file] | sign <zip> <tag> | verify <zip> <tag> <sig-file> <public-key>")
}
