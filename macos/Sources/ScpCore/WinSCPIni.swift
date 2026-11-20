import Foundation

/// Windows 版 WinSCP の設定ファイル (WinSCP.ini) から保存済みサイトを読む
public enum WinSCPIni {
    public struct Site: Equatable {
        public var path: String      // "フォルダ/サイト名"
        public var host: String
        public var port: Int
        public var user: String
        public var password: String
        public var proto: FileProtocol
        public var ftpSecurity: FTPSecurity
        public var keyFile: String
        public var remoteDirectory: String
        public init(path: String, host: String, port: Int, user: String, password: String, proto: FileProtocol,
                    ftpSecurity: FTPSecurity, keyFile: String = "", remoteDirectory: String = "") {
            self.path = path; self.host = host; self.port = port; self.user = user; self.password = password
            self.proto = proto; self.ftpSecurity = ftpSecurity; self.keyFile = keyFile; self.remoteDirectory = remoteDirectory
        }
    }

    public struct Result {
        public var sites: [Site] = []
        public var notes: [String] = []
    }

    /// %XX をもとに戻す (WinSCP は名前と値をこの形で書く)
    static func unescape(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.first {
            if c == UInt8(ascii: "%"), it.count >= 3,
               let v = UInt8(String(decoding: it.dropFirst().prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(v); it = it.dropFirst(3)
            } else {
                bytes.append(c); it = it.dropFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decodeText(_ data: Data) -> String {
        // regedit の書き出しは UTF-16 (BOM 付き)
        if data.count >= 2 && (data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// .reg の値: "文字列" (\\ と \" がエスケープ) / dword:0000001f
    static func regValue(_ v: String) -> String {
        if v.hasPrefix("dword:"), let n = UInt32(v.dropFirst(6), radix: 16) { return String(n) }
        guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { return v }
        var out = "", esc = false
        for c in v.dropFirst().dropLast() {
            if esc { out.append(c); esc = false } else if c == "\\" { esc = true } else { out.append(c) }
        }
        return out
    }

    /// WinSCP.ini (ツール → 設定のエクスポート) か、レジストリの書き出し (.reg) を読む
    public static func read(_ data: Data) -> Result {
        let text = decodeText(data)
        let isReg = text.hasPrefix("Windows Registry Editor") || text.hasPrefix("REGEDIT")
        var sections: [(String, [String: String])] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                var name = String(line.dropFirst().dropLast())
                // [HKEY_CURRENT_USER\Software\Martin Prikryl\WinSCP 2\Sessions\名前] → Sessions\名前
                if isReg {
                    guard let r = name.range(of: "\\Sessions\\") else { sections.append(("", [:])); continue }
                    name = "Sessions\\" + name[r.upperBound...]
                }
                sections.append((name, [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                var k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var v = String(line[line.index(after: eq)...])
                if isReg { k = regValue(k); v = regValue(v) }
                sections[sections.count - 1].1[k] = v
            }
        }
        var r = Result()
        for (name, kv) in sections where name.hasPrefix("Sessions\\") {
            let path = unescape(String(name.dropFirst("Sessions\\".count)))
            if path == "Default Settings" { continue }
            let host = unescape(kv["HostName"] ?? "")
            if host.isEmpty { continue }
            let fs = Int(kv["FSProtocol"] ?? "") ?? 1
            let proto: FileProtocol
            switch fs {
            case 0: proto = .scp
            case 1, 2: proto = .sftp
            case 5: proto = .ftp
            default:
                r.notes.append("「\(path)」は WebDAV / S3 のため読み込みませんでした")
                continue
            }
            let ftps = Int(kv["Ftps"] ?? "") ?? 0
            let sec: FTPSecurity = proto != .ftp ? .none : (ftps == 1 ? .implicitTLS : (ftps >= 2 ? .explicitTLS : .none))
            let defPort = proto == .ftp ? (sec == .implicitTLS ? 990 : 21) : 22
            let user = unescape(kv["UserName"] ?? "")
            var pw = ""
            if let enc = kv["Password"], !enc.isEmpty {
                pw = decryptPassword(enc, key: user + host) ?? ""
                if pw.isEmpty { r.notes.append("「\(path)」のパスワードは読み取れませんでした (マスターパスワードで保護されている可能性があります)") }
            }
            r.sites.append(Site(path: path, host: host, port: Int(kv["PortNumber"] ?? "") ?? defPort, user: user,
                                password: pw, proto: proto, ftpSecurity: sec,
                                keyFile: unescape(kv["PublicKeyFile"] ?? ""),
                                remoteDirectory: unescape(kv["RemoteDirectory"] ?? "")))
        }
        return r
    }

    // WinSCP の Security.cpp と同じ方式
    static let magic: UInt8 = 0xA3
    static let flag: UInt8 = 0xFF

    public static func decryptPassword(_ s: String, key: String) -> String? {
        var hex = Array(s.uppercased().utf8)[...]
        func next() -> UInt8? {
            guard hex.count >= 2 else { return nil }
            let h = String(decoding: hex.prefix(2), as: UTF8.self)
            hex = hex.dropFirst(2)
            guard let v = UInt8(h, radix: 16) else { return nil }
            return ~(v ^ magic)
        }
        guard let f = next() else { return nil }
        var length: Int
        if f == flag {
            guard let ver = next() else { return nil }
            if ver == 0 { length = Int(next() ?? 0) }
            else if ver == 2 { length = Int(next() ?? 0) << 8 + Int(next() ?? 0) }
            else { return nil }
        } else {
            length = Int(f)
        }
        guard let shift = next() else { return nil }
        hex = hex.dropFirst(Int(shift) * 2)
        var out: [UInt8] = []
        for _ in 0..<length { guard let c = next() else { return nil }; out.append(c) }
        var result = String(decoding: out, as: UTF8.self)
        if f == flag {
            guard result.hasPrefix(key) else { return nil }
            result.removeFirst(key.count)
        }
        return result
    }

    /// WinSCP と同じく、名前や値の特別な文字を %XX にする ("/" はフォルダの区切りなので残す)
    static func escape(_ s: String, keepSlash: Bool) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || "-_.@~:".contains(c) || (keepSlash && b == 0x2F) {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Windows 版 WinSCP で読める WinSCP.ini を作る (ツール → 設定のインポート/復元 で読み込める)
    public static func write(_ sites: [Site]) -> Data {
        var t = "; WinSCP Mac で書き出したサイト\r\n"
        for s in sites {
            t += "\r\n[Sessions\\\(escape(s.path, keepSlash: true))]\r\n"
            t += "HostName=\(escape(s.host, keepSlash: false))\r\n"
            t += "PortNumber=\(s.port)\r\n"
            if !s.user.isEmpty { t += "UserName=\(escape(s.user, keepSlash: false))\r\n" }
            if !s.password.isEmpty { t += "Password=\(encryptPassword(s.password, key: s.user + s.host))\r\n" }
            let fs: Int
            switch s.proto { case .scp: fs = 0; case .sftp: fs = 2; case .ftp: fs = 5 }
            t += "FSProtocol=\(fs)\r\n"
            if s.proto == .ftp && s.ftpSecurity != .none { t += "Ftps=\(s.ftpSecurity == .implicitTLS ? 1 : 3)\r\n" }
            if !s.remoteDirectory.isEmpty { t += "RemoteDirectory=\(escape(s.remoteDirectory, keepSlash: true))\r\n" }
        }
        return Data(t.utf8)
    }

    /// WinSCP と同じ形式で暗号化する (WinSCP はさらに乱数で詰めるが、読むときには不要)
    public static func encryptPassword(_ pw: String, key: String) -> String {
        let data = Array((key + pw).utf8)
        func enc(_ c: UInt8) -> String { String(format: "%02X", ~c ^ magic) }
        var s = enc(flag) + enc(0) + enc(UInt8(data.count)) + enc(0)
        for c in data { s += enc(c) }
        return s
    }
}
