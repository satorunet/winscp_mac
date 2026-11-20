import Foundation

/// WinSCP のセッションの設定 (WinSCP.ini のセッションのキー名 → 値) を、
/// WinSCP (SessionData.cpp の Load/Save) と同じ規則・同じ既定値で読み書きする。
public struct WinSCPSessionData {
    public var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }

    /// WinSCP の TAutoSwitch (asOn = 0, asOff = 1, asAuto = 2)
    public enum AutoSwitch: Int { case on = 0, off = 1, auto = 2 }

    public func has(_ k: String) -> Bool { values[k] != nil }
    public func string(_ k: String, _ def: String = "") -> String { values[k] ?? def }
    public func int(_ k: String, _ def: Int) -> Int {
        guard let v = values[k]?.trimmingCharacters(in: .whitespaces) else { return def }
        return Int(v) ?? def
    }
    public func bool(_ k: String, _ def: Bool) -> Bool {
        guard let v = values[k]?.trimmingCharacters(in: .whitespaces).lowercased() else { return def }
        if let n = Int(v) { return n != 0 }
        if ["on", "true", "yes"].contains(v) { return true }
        if ["off", "false", "no"].contains(v) { return false }
        return def
    }
    /// ReadEnum と同じく、数字でも "on"/"off"/"auto" でも読める
    public func autoSwitch(_ k: String, _ def: AutoSwitch = .auto) -> AutoSwitch {
        guard let v = values[k]?.trimmingCharacters(in: .whitespaces).lowercased() else { return def }
        if let n = Int(v) { return AutoSwitch(rawValue: n) ?? def }
        switch v { case "on": return .on; case "off": return .off; case "auto": return .auto; default: return def }
    }

    public mutating func set(_ k: String, _ v: String?) { values[k] = v }
    public mutating func set(_ k: String, _ v: Bool) { values[k] = v ? "1" : "0" }
    public mutating func set(_ k: String, _ v: Int) { values[k] = String(v) }

    // MARK: 値の変換が特別なもの

    /// 接続の保持の間隔 (秒)。WinSCP は分 (PingInterval) と秒 (PingIntervalSecs) に分けて保存する
    public var pingInterval: Int {
        get {
            let secs = values["PingIntervalSecs"].flatMap { Int($0) } ?? values["PingIntervalSec"].flatMap { Int($0) } ?? 30
            let r = int("PingInterval", 0) * 60 + secs
            return r == 0 ? 30 : r
        }
        set {
            values["PingInterval"] = String(newValue / 60)
            values["PingIntervalSecs"] = String(newValue % 60)
            values["PingIntervalSec"] = nil
        }
    }

    /// タイムゾーン補正 (分)。WinSCP は TDateTime (日単位の double) を 16 桁の 16 進 (リトルエンディアン) で保存する
    public var timeDifferenceMinutes: Int {
        get {
            guard let s = values["TimeDifference"], let d = WinSCPSessionData.decodeFloat(s) else { return 0 }
            return Int((d * 24 * 60).rounded())
        }
        set { values["TimeDifference"] = WinSCPSessionData.encodeFloat(Double(newValue) / (24 * 60)) }
    }

    public static func decodeFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count == 16, t.allSatisfy({ $0.isHexDigit }) {
            var bytes: [UInt8] = []
            var i = t.startIndex
            while i < t.endIndex {
                let j = t.index(i, offsetBy: 2)
                bytes.append(UInt8(t[i..<j], radix: 16) ?? 0)
                i = j
            }
            var bits: UInt64 = 0
            for (k, b) in bytes.enumerated() { bits |= UInt64(b) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    public static func encodeFloat(_ d: Double) -> String {
        let bits = d.bitPattern
        return (0..<8).map { String(format: "%02X", UInt8((bits >> (8 * UInt64($0))) & 0xff)) }.joined()
    }

    /// TimeDifferenceAuto の既定は「TimeDifference が 0 なら true」
    public var timeDifferenceAuto: Bool { bool("TimeDifferenceAuto", timeDifferenceMinutes == 0) }

    /// ProxyDNS は (値 + 2) % 3 で保存される
    public var proxyDNS: AutoSwitch {
        get { AutoSwitch(rawValue: (int("ProxyDNS", (AutoSwitch.auto.rawValue + 2) % 3) + 1) % 3) ?? .auto }
        set { values["ProxyDNS"] = String((newValue.rawValue + 2) % 3) }
    }

    /// Bug* は 2 - 値 で保存される
    public func bug(_ name: String) -> AutoSwitch { AutoSwitch(rawValue: 2 - int("Bug" + name, 2 - AutoSwitch.auto.rawValue)) ?? .auto }
    public mutating func setBug(_ name: String, _ v: AutoSwitch) { values["Bug" + name] = String(2 - v.rawValue) }

    /// プロキシの種類 (pmNone, pmSocks4, pmSocks5, pmHTTP, pmTelnet, pmCmd)
    public static let proxyMethodNames = ["none", "socks4", "socks5", "http", "telnet", "cmd"]
    public var proxyMethod: Int {
        let v = string("ProxyMethod").trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(v) { return n }
        return WinSCPSessionData.proxyMethodNames.firstIndex(of: v) ?? 0
    }
    /// ローカル プロキシ コマンドは pmCmd のとき ProxyTelnetCommand に保存される
    public var proxyTelnetCommand: String { proxyMethod == 5 ? "connect %host %port\\n" : string("ProxyTelnetCommand", "connect %host %port\\n") }
    public var proxyLocalCommand: String { proxyMethod == 5 ? string("ProxyTelnetCommand") : "" }

    /// パスワード類: 平文のキーがあればそれ、無ければ暗号化されたキーを WinSCP の方式で戻す
    public func password(plain: String, encrypted: String, key: String) -> String {
        if let p = values[plain] { return p }
        guard let e = values[encrypted], !e.isEmpty else { return "" }
        return WinSCPIni.decryptPassword(e, key: key) ?? ""
    }
    public mutating func setPassword(_ pw: String, plain: String, encrypted: String, key: String) {
        values[plain] = nil
        values[encrypted] = pw.isEmpty ? nil : WinSCPIni.encryptPassword(pw, key: key)
    }
    public var proxyPassword: String {
        password(plain: "ProxyPassword", encrypted: "ProxyPasswordEnc", key: string("ProxyUsername") + string("ProxyHost", "proxy"))
    }
    public var tunnelPassword: String {
        password(plain: "TunnelPasswordPlain", encrypted: "TunnelPassword", key: string("TunnelUserName") + string("TunnelHostName"))
    }

    // MARK: アルゴリズムの順番 (SessionData.cpp の SetAlgoList と同じ)

    public static let cipherNames = ["WARN", "3des", "blowfish", "aes", "des", "arcfour", "chacha20", "aesgcm"]
    public static let defaultCiphers = ["aes", "chacha20", "aesgcm", "3des", "WARN", "des", "blowfish", "arcfour"]
    public static let kexNames = ["WARN", "dh-group1-sha1", "dh-group14-sha1", "dh-group15-sha512", "dh-group16-sha512",
                                  "dh-group17-sha512", "dh-group18-sha512", "dh-gex-sha1", "rsa", "ecdh",
                                  "ntru-curve25519", "mlkem-curve25519", "mlkem-nist"]
    public static let defaultKex = ["ntru-curve25519", "mlkem-curve25519", "mlkem-nist", "ecdh", "dh-gex-sha1",
                                    "dh-group18-sha512", "dh-group17-sha512", "dh-group16-sha512", "dh-group15-sha512",
                                    "dh-group14-sha1", "rsa", "WARN", "dh-group1-sha1"]

    public var ciphers: [String] { WinSCPSessionData.algoList(string("Cipher"), names: WinSCPSessionData.cipherNames, defaults: WinSCPSessionData.defaultCiphers) }
    public var kex: [String] { WinSCPSessionData.algoList(string("KEX"), names: WinSCPSessionData.kexNames, defaults: WinSCPSessionData.defaultKex) }

    /// 保存された並び (足りないものは既定の位置に補う)
    public static func algoList(_ value: String, names: [String], defaults: [String]) -> [String] {
        let count = names.count
        var used = Set<String>()
        var list: [String] = []
        for part in value.split(separator: ",") {
            let s = part.trimmingCharacters(in: .whitespaces)
            if let n = names.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }), !used.contains(n), list.count < count {
                list.append(n); used.insert(n)
            }
        }
        if !used.contains("WARN") { list.append("WARN"); used.insert("WARN") }
        var warnIndex = list.firstIndex(of: "WARN")!
        let warnDefaultIndex = defaults.firstIndex(of: "WARN")!
        var priority = true
        for (di, d) in defaults.enumerated() {
            if !used.contains(d) {
                let target: Int
                if priority { target = di }
                else { target = di < warnDefaultIndex ? warnIndex : list.count }
                list.insert(d, at: min(target, list.count))
                used.insert(d)
                if target <= warnIndex { warnIndex += 1 }
            } else {
                priority = false
            }
        }
        return list
    }
}

/// ssh に渡すオプションなど (サイトの設定から作る)
public struct SSHOptionSet: Equatable {
    /// ssh にそのまま渡す引数 (-o ... など)
    public var args: [String] = []
    /// エージェントの転送 (-a を付けない)
    public var forwardAgent = false
    /// SFTP サーバーのコマンド (空ならサブシステム "sftp")
    public var sftpServer = ""
    /// SFTP が使えないとき SCP にする
    public var scpFallback = false
    public init() {}
}

/// WinSCP の設定 → OpenSSH (/usr/bin/ssh) / FTP クライアントの設定
public enum SessionOptions {
    // MARK: 暗号・鍵交換の名前 (WinSCP → OpenSSH)

    public static let opensshCiphers: [String: [String]] = [
        "aes": ["aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-cbc", "aes192-cbc", "aes256-cbc"],
        "chacha20": ["chacha20-poly1305@openssh.com"],
        "aesgcm": ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"],
        "3des": ["3des-cbc"],
        "des": [], "blowfish": ["blowfish-cbc"], "arcfour": ["arcfour256", "arcfour128", "arcfour"],
    ]
    public static let opensshKex: [String: [String]] = [
        "ntru-curve25519": ["sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com"],
        "mlkem-curve25519": ["mlkem768x25519-sha256"],
        "mlkem-nist": [],
        "ecdh": ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521"],
        "dh-gex-sha1": ["diffie-hellman-group-exchange-sha256", "diffie-hellman-group-exchange-sha1"],
        "dh-group18-sha512": ["diffie-hellman-group18-sha512"],
        "dh-group17-sha512": [],
        "dh-group16-sha512": ["diffie-hellman-group16-sha512"],
        "dh-group15-sha512": [],
        "dh-group14-sha1": ["diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1"],
        "rsa": [],
        "dh-group1-sha1": ["diffie-hellman-group1-sha1"],
    ]

    /// この Mac の ssh が対応しているアルゴリズム (ssh -Q)
    public static func supported(_ what: String) -> Set<String> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache[what] { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        p.arguments = ["-Q", what]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var r = Set<String>()
        if (try? p.run()) != nil {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            r = Set(String(decoding: d, as: UTF8.self).split(whereSeparator: { $0.isNewline }).map(String.init))
        }
        cache[what] = r
        return r
    }
    private static var cache: [String: Set<String>] = [:]
    private static let cacheLock = NSLock()

    /// WinSCP の並び → OpenSSH の名前の並び (「警告レベル」より上だけ。ssh が知らないものは除く)
    public static func opensshAlgorithms(_ list: [String], map: [String: [String]], supported: Set<String>) -> [String] {
        var out: [String] = []
        for a in list {
            if a == "WARN" { break }
            for n in map[a] ?? [] where supported.contains(n) && !out.contains(n) { out.append(n) }
        }
        return out
    }

    // MARK: プロキシのコマンド (PuTTY の format_telnet_command と同じパターン)

    /// \n \r \t \xXX \\ と %host %port %user %pass %proxyhost %proxyport %% を展開する
    public static func formatProxyCommand(_ fmt: String, host: String, port: Int, proxyHost: String, proxyPort: Int,
                                          user: String, password: String) -> String {
        var out = ""
        let c = Array(fmt)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" && i + 1 < c.count {
                let n = c[i + 1]
                switch n {
                case "\\": out.append("\\"); i += 2
                case "b": out.append("\u{8}"); i += 2
                case "f": out.append("\u{c}"); i += 2
                case "n": out.append("\n"); i += 2
                case "r": out.append("\r"); i += 2
                case "t": out.append("\t"); i += 2
                case "v": out.append("\u{b}"); i += 2
                case "x", "X":
                    var j = i + 2, v = 0, k = 0
                    while j < c.count, k < 2, let h = c[j].hexDigitValue { v = v * 16 + h; j += 1; k += 1 }
                    if k > 0, let u = UnicodeScalar(v) { out.append(Character(u)); i = j } else { out.append(ch); i += 1 }
                default: out.append(ch); i += 1
                }
                continue
            }
            if ch == "%" {
                let rest = String(c[(i + 1)...])
                let subs: [(String, String)] = [("%", "%"), ("proxyhost", proxyHost), ("proxyport", String(proxyPort)),
                                                 ("host", host), ("port", String(port)), ("user", user), ("pass", password)]
                if let (k, v) = subs.first(where: { rest.lowercased().hasPrefix($0.0) }) {
                    out += v
                    i += 1 + k.count
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// ssh の ProxyCommand では % が特別 (%h %p など) なので %% にする
    public static func sshEscape(_ s: String) -> String { s.replacingOccurrences(of: "%", with: "%%") }

    /// sh の printf で 1 バイトずつ 8 進で書く (どんな文字でも安全)
    static func printfOctal(_ s: String) -> String {
        "printf '" + s.utf8.map { String(format: "\\%03o", $0) }.joined() + "'"
    }

    /// 接続先 host:port へのプロキシの ProxyCommand (ssh の % 展開前の形)。プロキシなしなら nil
    public static func proxyCommand(_ d: WinSCPSessionData, host: String, port: Int) -> String? {
        let method = d.proxyMethod
        let ph = d.string("ProxyHost", "proxy")
        let pp = d.int("ProxyPort", 80)
        let target = host.contains(":") ? "[\(host)]" : host
        switch method {
        case 1, 2, 3:
            let x = method == 1 ? "4" : (method == 2 ? "5" : "connect")
            return sshEscape("/usr/bin/nc -X \(x) -x \(ph):\(pp) \(SSHSession.quote(target)) \(port)")
        case 4:
            let cmd = formatProxyCommand(d.proxyTelnetCommand, host: host, port: port, proxyHost: ph, proxyPort: pp,
                                         user: d.string("ProxyUsername"), password: d.proxyPassword)
            return sshEscape("(\(printfOctal(cmd)); exec cat) | /usr/bin/nc \(SSHSession.quote(ph)) \(pp)")
        case 5:
            let cmd = formatProxyCommand(d.proxyLocalCommand, host: host, port: port, proxyHost: ph, proxyPort: pp,
                                         user: d.string("ProxyUsername"), password: d.proxyPassword)
            return cmd.isEmpty ? nil : sshEscape(cmd)
        default:
            return nil
        }
    }

    // MARK: SSH

    /// サイトの設定 → ssh の引数など。
    /// supportedCiphers / supportedKex は ssh -Q の結果 (テストでは固定値を渡す)
    public static func ssh(_ d: WinSCPSessionData, host: String, port: Int,
                           supportedCiphers: Set<String>? = nil, supportedKex: Set<String>? = nil,
                           tunnelExtraArgs: [String] = []) -> SSHOptionSet {
        var r = SSHOptionSet()
        var a: [String] = []
        func o(_ s: String) { a += ["-o", s] }

        // 接続
        let ping = d.int("PingType", 0)
        o("ServerAliveInterval=\(ping == 0 ? 0 : max(1, d.pingInterval))")
        o("ConnectTimeout=\(max(1, d.int("Timeout", 15)))")
        switch d.int("AddressFamily", 0) {
        case 1: o("AddressFamily=inet")
        case 2: o("AddressFamily=inet6")
        default: break
        }
        // SSH
        if d.bool("Compression", false) { o("Compression=yes") }
        if d.has("Cipher") {
            let c = d.ciphers
            if c != WinSCPSessionData.defaultCiphers {
                let names = opensshAlgorithms(c, map: opensshCiphers, supported: supportedCiphers ?? supported("cipher"))
                if !names.isEmpty { o("Ciphers=" + names.joined(separator: ",")) }
            }
        }
        // 鍵交換
        if d.has("KEX") {
            let k = d.kex
            if k != WinSCPSessionData.defaultKex {
                let names = opensshAlgorithms(k, map: opensshKex, supported: supportedKex ?? supported("kex"))
                if !names.isEmpty { o("KexAlgorithms=" + names.joined(separator: ",")) }
            }
        }
        let rekeyData = d.string("RekeyBytes", "1G").trimmingCharacters(in: .whitespaces)
        let rekeyTime = d.int("RekeyTime", 60)
        if d.bug("Rekey2") != .on && (rekeyData.uppercased() != "1G" || rekeyTime != 60) {
            let data = rekeyData.isEmpty || rekeyData == "0" ? "default" : rekeyData
            o("RekeyLimit=\(data) \(rekeyTime == 0 ? "none" : String(rekeyTime * 60))")
        }
        // 認証
        if !d.bool("TryAgent", true) { o("IdentityAgent=none") }
        if !d.bool("AuthKI", true) { o("KbdInteractiveAuthentication=no") }
        o("GSSAPIAuthentication=\(d.bool("AuthGSSAPI", true) ? "yes" : "no")")
        if d.bool("AuthGSSAPI", true) && d.bool("GSSAPIFwdTGT", false) { o("GSSAPIDelegateCredentials=yes") }
        if d.bool("TryAgent", true) && d.bool("AgentFwd", false) {
            o("ForwardAgent=yes")
            r.forwardAgent = true
        }
        let cert = d.string("DetachedCertificate")
        if !cert.isEmpty && !cert.contains("\\") { o("CertificateFile=" + (cert as NSString).expandingTildeInPath) }

        // トンネル (WinSCP の「SSH トンネルを経由して接続する」) → 踏み台の ssh -W
        if d.bool("Tunnel", false) && !d.string("TunnelHostName").isEmpty {
            var t: [String] = [SSHSession.sshPath] + tunnelExtraArgs.map { SSHSession.quote($0) }
            t += ["-o", "ConnectTimeout=\(max(1, d.int("Timeout", 15)))"]
            switch d.int("AddressFamily", 0) {
            case 1: t += ["-4"]
            case 2: t += ["-6"]
            default: break
            }
            let tp = d.int("TunnelPortNumber", 22)
            if tp != 22 && tp > 0 { t += ["-p", String(tp)] }
            let tu = d.string("TunnelUserName")
            if !tu.isEmpty { t += ["-l", SSHSession.quote(tu)] }
            let tk = d.string("TunnelPublicKeyFile")
            if !tk.isEmpty && !tk.contains("\\") { t += ["-i", SSHSession.quote((tk as NSString).expandingTildeInPath)] }
            let th = d.string("TunnelHostName")
            // 踏み台へのプロキシ (WinSCP ではプロキシはトンネルの接続に使われる)
            if let pc = proxyCommand(d, host: th, port: tp) {
                t += [SSHSession.quote("-oProxyCommand=" + pc)]
            }
            var cmd = t.map { sshEscape($0) }.joined(separator: " ")
            cmd += " -W %h:%p " + sshEscape(SSHSession.quote(th))
            o("ProxyCommand=" + cmd)
        } else if let pc = proxyCommand(d, host: host, port: port) {
            o("ProxyCommand=" + pc)
        }

        // SFTP
        let server = d.string("SftpServer")
        r.sftpServer = server
        // FSProtocol: 0 SCP, 1 SFTP (SCP へのフォールバックあり), 2 SFTP のみ
        r.scpFallback = server.isEmpty && d.int("FSProtocol", 1) == 1
        r.args = a
        return r
    }

    // MARK: FTP

    /// サイトの設定を FTP の接続の設定に反映する
    public static func ftp(_ d: WinSCPSessionData, _ p: FTPClient.Params) -> FTPClient.Params {
        var p = p
        p.timeout = TimeInterval(max(1, d.int("Timeout", 15)))
        p.forcePasvIP = d.autoSwitch("FtpForcePasvIp2")
        p.useMLSD = d.autoSwitch("FtpUseMlsd")
        p.listAll = d.autoSwitch("FtpListAll")
        p.sendHost = d.autoSwitch("FtpHost") == .on
        p.account = d.string("FtpAccount")
        p.postLoginCommands = d.string("PostLoginCommands")
            .components(separatedBy: CharacterSet.newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.minTLS = d.int("MinTlsVersion", 12)
        p.maxTLS = d.int("MaxTlsVersion", 13)
        p.tlsSessionReuse = d.bool("SslSessionReuse", true)
        switch d.int("AddressFamily", 0) {
        case 1: p.addressFamily = AF_INET
        case 2: p.addressFamily = AF_INET6
        default: p.addressFamily = AF_UNSPEC
        }
        // プロキシ: SOCKS4 / SOCKS5 だけ (FtpProxyLogonType が 0 のとき)
        let m = d.proxyMethod
        if (m == 1 || m == 2) && d.int("FtpProxyLogonType", 0) == 0 {
            p.socksProxy = FTPClient.SOCKSProxy(version: m == 1 ? 4 : 5, host: d.string("ProxyHost", "proxy"),
                                                port: d.int("ProxyPort", 80), user: d.string("ProxyUsername"),
                                                password: d.proxyPassword)
            p.passive = true
        }
        // タイムゾーン補正 (MLSD を使わず、自動認識でないとき)
        if d.autoSwitch("FtpUseMlsd") == .off && !d.timeDifferenceAuto {
            p.timeDifference = TimeInterval(d.timeDifferenceMinutes * 60)
        }
        return p
    }
}
