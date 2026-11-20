import Foundation
import Security
import CommonCrypto

/// FTP / FTPS (明示的・暗黙的 TLS) のクライアント
public final class FTPClient: RemoteFileSystem {
    public var protocolName: String { security == .none ? "FTP" : "FTPS" }

    public struct Params {
        public var host: String
        public var port: Int
        public var user: String
        public var password: String
        public var security: FTPSecurity
        public var passive: Bool
        // 以下は WinSCP の「高度なサイトの設定」から (SessionOptions.ftp で設定する)
        /// サーバーの応答を待つ時間 (秒)
        public var timeout: TimeInterval = 60
        /// パッシブ モードで、サーバーが返した IP アドレスの代わりに接続先のアドレスを使う (自動: 内部アドレスのときだけ)
        public var forcePasvIP: WinSCPSessionData.AutoSwitch = .auto
        /// 一覧に MLSD を使う (自動: サーバーが対応していれば)
        public var useMLSD: WinSCPSessionData.AutoSwitch = .auto
        /// 隠しファイルも一覧する (LIST -a)。自動: -a を試し、だめなら LIST
        public var listAll: WinSCPSessionData.AutoSwitch = .auto
        /// ログインの前に HOST コマンドを送る
        public var sendHost = false
        /// ACCT のアカウント
        public var account = ""
        /// ログインの後に送るコマンド
        public var postLoginCommands: [String] = []
        /// TLS の最小/最大バージョン (10 = 1.0 ... 13 = 1.3)
        public var minTLS = 12
        public var maxTLS = 13
        /// データ接続で制御接続の TLS セッションを使い回す
        public var tlsSessionReuse = true
        /// AF_INET / AF_INET6 / AF_UNSPEC
        public var addressFamily: Int32 = AF_UNSPEC
        /// SOCKS プロキシ
        public var socksProxy: SOCKSProxy?
        /// 一覧の時刻に足す秒数 (タイムゾーン補正)
        public var timeDifference: TimeInterval = 0

        public init(host: String, port: Int = 21, user: String = "", password: String = "", security: FTPSecurity = .none, passive: Bool = true) {
            self.host = host; self.port = port; self.user = user; self.password = password; self.security = security; self.passive = passive
        }
    }

    public struct SOCKSProxy: Equatable {
        public var version: Int   // 4 か 5
        public var host: String
        public var port: Int
        public var user: String
        public var password: String
        public init(version: Int, host: String, port: Int, user: String = "", password: String = "") {
            self.version = version; self.host = host; self.port = port; self.user = user; self.password = password
        }
    }

    /// 検証できなかった証明書を受け入れるかどうか聞く (説明文, SHA-256 指紋) → 受け入れるなら true
    public typealias CertificateHandler = (_ summary: String, _ fingerprint: String) -> Bool

    let params: Params
    var security: FTPSecurity { params.security }
    private var ctrl: FTPStream?
    private var features: Set<String> = []
    private var acceptedFingerprints: Set<String> = []
    private let certHandler: CertificateHandler
    public private(set) var welcome = ""
    /// 通信の記録 (ログ表示用)
    public var log: ((String) -> Void)?

    public init(_ params: Params, certificateHandler: @escaping CertificateHandler) throws {
        self.params = params
        certHandler = certificateHandler
        try connect()
    }

    // MARK: 接続

    private func connect() throws {
        ctrl?.close()
        let s = try newStream(host: params.host, port: params.port)
        ctrl = s
        if security == .implicitTLS { try startTLS(s) }
        let g = try reply()
        guard g.code == 220 else { throw RemoteError("サーバーの応答: \(g.text)") }
        welcome = g.text
        if params.sendHost {
            // HOST コマンド (RFC 7151)。対応していないサーバーもあるので結果は見ない
            _ = try command("HOST " + params.host)
        }
        if security == .explicitTLS {
            var r = try command("AUTH TLS")
            if r.code != 234 { r = try command("AUTH SSL") }
            guard r.code == 234 || r.code == 334 else { throw RemoteError("サーバーが TLS に対応していません: \(r.text)") }
            try startTLS(s)
        }
        var r = try command("USER " + (params.user.isEmpty ? "anonymous" : params.user))
        if r.code == 331 || r.code == 332 {
            r = try command("PASS " + (params.user.isEmpty && params.password.isEmpty ? "anonymous@" : params.password), secret: true)
        }
        if r.code == 332 {
            r = try command("ACCT " + params.account)
        }
        guard r.code == 230 || r.code == 202 else { throw RemoteError("認証に失敗しました。\n\n\(r.text)") }
        if security != .none {
            _ = try command("PBSZ 0")
            _ = try command("PROT P")
        }
        let f = try command("FEAT")
        if f.code == 211 {
            features = Set(f.lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.map {
                String($0.split(separator: " ").first ?? "")
            })
        }
        if features.contains("UTF8") { _ = try? command("OPTS UTF8 ON") }
        _ = try command("TYPE I")
        // ログイン コマンド (WinSCP の「ログイン コマンドの送信」)
        for c in params.postLoginCommands { _ = try command(c) }
    }

    /// 制御接続・データ接続のつなぎ方 (タイムアウト・IP バージョン・SOCKS プロキシ)
    private func newStream(host: String, port: Int) throws -> FTPStream {
        try FTPStream(host: host, port: port, timeout: params.timeout, family: params.addressFamily, socks: params.socksProxy)
    }

    /// 接続の保持 (WinSCP の「ダミー コマンドを送信する」)
    public func keepAlive() throws {
        try retrying { _ = try command("NOOP") }
    }

    /// MLSD を使うか
    private var mlsd: Bool {
        switch params.useMLSD {
        case .on: return true
        case .off: return false
        case .auto: return features.contains("MLSD")
        }
    }

    private func startTLS(_ s: FTPStream) throws {
        try s.startTLS(host: params.host, sessionID: tlsSessionID, minTLS: params.minTLS, maxTLS: params.maxTLS)
        try verify(s)
    }

    /// 制御接続とデータ接続で同じ TLS セッションを使うための名前
    private lazy var tlsSessionID = "winscpmac-\(params.host):\(params.port)-\(UUID().uuidString)"

    private func verify(_ s: FTPStream) throws {
        guard let trust = s.peerTrust() else { return }
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) { return }
        let fp = FTPClient.fingerprint(trust)
        if acceptedFingerprints.contains(fp) { return }
        var summary = params.host
        if SecTrustGetCertificateCount(trust) > 0, let cert = SecTrustGetCertificateAtIndex(trust, 0),
           let subj = SecCertificateCopySubjectSummary(cert) as String? {
            summary = subj
        }
        let reason = (err as Error?)?.localizedDescription ?? ""
        if certHandler("証明書: \(summary)\n\(reason)", fp) {
            acceptedFingerprints.insert(fp)
        } else {
            throw RemoteError("証明書を受け入れなかったため、接続を中止しました")
        }
    }

    static func fingerprint(_ trust: SecTrust) -> String {
        guard SecTrustGetCertificateCount(trust) > 0, let cert = SecTrustGetCertificateAtIndex(trust, 0) else { return "" }
        let der = SecCertificateCopyData(cert) as Data
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        der.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(der.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: 返事

    struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: "\n") }
        var message: String {
            lines.map { l -> String in
                l.count > 4 && Int(l.prefix(3)) != nil ? String(l.dropFirst(4)) : l
            }.joined(separator: "\n")
        }
    }

    private func reply() throws -> Reply {
        guard let s = ctrl else { throw RemoteError("接続されていません") }
        var lines: [String] = []
        let first = try s.readLine()
        lines.append(first)
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw RemoteError("不正な応答: \(first)") }
        if first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let end = "\(first.prefix(3)) "
            while true {
                let l = try s.readLine()
                lines.append(l)
                if l.hasPrefix(end) || l == String(first.prefix(3)) { break }
            }
        }
        log?(lines.joined(separator: "\n"))
        return Reply(code: code, lines: lines)
    }

    @discardableResult
    private func command(_ cmd: String, secret: Bool = false) throws -> Reply {
        guard let s = ctrl else { throw RemoteError("接続されていません") }
        log?(secret ? "PASS ****" : cmd)
        try s.write(cmd + "\r\n")
        return try reply()
    }

    /// 接続が切れていたらつなぎ直して、もう一度だけやってみる
    private func retrying<R>(_ body: () throws -> R) throws -> R {
        do { return try body() } catch let e as RemoteError where e.code == FTPStream.closedCode || e.code == 421 {
            try connect()
            return try body()
        }
    }

    private func ok(_ r: Reply, _ codes: ClosedRange<Int> = 200...299, _ path: String = "") throws {
        guard codes.contains(r.code) else {
            if r.code == 421 { throw RemoteError(r.message, code: 421) }
            throw RemoteError(path.isEmpty ? r.message : "\(path): \(r.message)", code: r.code)
        }
    }

    // MARK: データ接続

    /// データ接続を用意する。パッシブ モードならここでつなぎ、アクティブ モードなら待ち受けて PORT/EPRT を送る
    private func openData() throws -> FTPDataChannel {
        if !params.passive && params.socksProxy == nil, let ctrl = ctrl {
            return try openActiveData(ctrl)
        }
        var port = 0
        var host = params.host
        let e = try command("EPSV")
        if e.code == 229, let l = e.text.range(of: "(|||"), let r = e.text[l.upperBound...].firstIndex(of: "|") {
            port = Int(e.text[l.upperBound..<r]) ?? 0
        } else {
            let p = try command("PASV")
            try ok(p)
            // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)
            let nums = p.text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count >= 7 else { throw RemoteError("PASV の応答を読めません: \(p.text)") }
            let n = Array(nums.suffix(6))
            port = n[4] * 256 + n[5]
            let ip = n[0...3].map(String.init).joined(separator: ".")
            switch params.forcePasvIP {
            case .on:
                break
            case .off:
                host = ip
            case .auto:
                // 内部アドレスや 0.0.0.0 を返すサーバーがあるので、そういうときは接続先のホストを使う
                if !(ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("172.") || ip == "0.0.0.0" || ip.hasPrefix("127.")) {
                    host = ip
                }
            }
        }
        guard port > 0 else { throw RemoteError("データ接続のポートが分かりません") }
        return FTPDataChannel(stream: try newStream(host: host, port: port))
    }

    /// アクティブ モード: 制御接続と同じ自分のアドレスで待ち受け、PORT (IPv6 なら EPRT) を送る
    private func openActiveData(_ ctrl: FTPStream) throws -> FTPDataChannel {
        guard let local = ctrl.localAddress() else { throw RemoteError("自分のアドレスが分かりません (アクティブ モード)") }
        let ch = try FTPDataChannel(listenOn: local, timeout: params.timeout)
        let port = ch.listenPort
        if local.family == AF_INET {
            let p = local.ip.split(separator: ".").joined(separator: ",") + ",\(port / 256),\(port % 256)"
            try ok(try command("PORT " + p))
        } else {
            try ok(try command("EPRT |2|\(local.ip)|\(port)|"))
        }
        return ch
    }

    private func dataTLS(_ d: FTPStream) throws {
        if security != .none {
            // セッション ID を使い回さないときは、データ接続ごとに別の名前にする
            let id = params.tlsSessionReuse ? tlsSessionID : "winscpmac-data-\(UUID().uuidString)"
            try d.startTLS(host: params.host, sessionID: id, minTLS: params.minTLS, maxTLS: params.maxTLS)
            try verify(d)
        }
    }

    /// データ接続を開き、コマンドを送り、データを受け取る
    private func transferIn(_ cmd: String, path: String, sink: (Data) throws -> Bool) throws {
        let ch = try openData()
        defer { ch.close() }
        let r = try command(cmd)
        guard r.code == 150 || r.code == 125 else {
            try ok(r, 100...199, path)
            return
        }
        let d = try ch.connected()
        try dataTLS(d)
        var cancelled = false
        while true {
            let chunk = try d.read(max: 65536)
            if chunk.isEmpty { break }
            if try !sink(chunk) { cancelled = true; break }
        }
        d.close()
        if cancelled {
            _ = try? command("ABOR")
            // ABOR の後は 426 と 226 が来ることがある
            _ = try? reply()
            throw RemoteError.cancelled
        }
        let f = try reply()
        try ok(f, 200...299, path)
    }

    // MARK: RemoteFileSystem

    public func homeDirectory() throws -> String {
        try retrying {
            let r = try command("PWD")
            try ok(r)
            if let a = r.text.firstIndex(of: "\""), let b = r.text[r.text.index(after: a)...].lastIndex(of: "\"") {
                return String(r.text[r.text.index(after: a)..<b]).replacingOccurrences(of: "\"\"", with: "\"")
            }
            return "/"
        }
    }

    private func decode(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .shiftJIS) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    public func list(_ path: String) throws -> [FileEntry] {
        try retrying {
            var data = Data()
            if mlsd {
                try transferIn("MLSD " + path, path: path) { data.append($0); return true }
                return decode(data).split(whereSeparator: { $0.isNewline }).compactMap {
                    ListParser.parseMLSDLine(String($0))
                }
            }
            let c = try command("CWD " + path)
            try ok(c, 200...299, path)
            switch params.listAll {
            case .on:
                try transferIn("LIST -a", path: path) { data.append($0); return true }
            case .off:
                try transferIn("LIST", path: path) { data.append($0); return true }
            case .auto:
                do {
                    try transferIn("LIST -a", path: path) { data.append($0); return true }
                } catch let e as RemoteError where e.code >= 500 {
                    data = Data()
                    try transferIn("LIST", path: path) { data.append($0); return true }
                }
            }
            var list = ListParser.parseUnixList(decode(data), utc: false)
            if params.timeDifference != 0 {
                for i in list.indices { list[i].mtime = list[i].mtime?.addingTimeInterval(params.timeDifference) }
            }
            return list
        }
    }

    public func stat(_ path: String) throws -> FileEntry {
        try retrying {
            if features.contains("MLST") && params.useMLSD != .off {
                let r = try command("MLST " + path)
                if r.code == 250, r.lines.count >= 2,
                   var e = ListParser.parseMLSDLine(r.lines[1].trimmingCharacters(in: .whitespaces)) {
                    e.name = RemotePath.name(path)
                    return e
                }
            }
            let cwd = try homeDirectory()
            if try command("CWD " + path).code == 250 {
                _ = try command("CWD " + cwd)
                return FileEntry(name: RemotePath.name(path), isDirectory: true)
            }
            let s = try command("SIZE " + path)
            guard s.code == 213 else { throw RemoteError("\(path): \(s.message)", code: s.code) }
            var e = FileEntry(name: RemotePath.name(path), isDirectory: false, size: UInt64(s.message.trimmingCharacters(in: .whitespaces)) ?? 0)
            let m = try command("MDTM " + path)
            if m.code == 213 { e.mtime = ListParser.parseMDTM(m.message.trimmingCharacters(in: .whitespaces)) }
            return e
        }
    }

    public func download(_ remote: String, to local: URL, offset: UInt64, progress: ProgressHandler) throws {
        if offset == 0 || !FileManager.default.fileExists(atPath: local.path) {
            guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
                throw RemoteError("\(local.path): ファイルを作れません")
            }
        }
        let fh = try FileHandle(forWritingTo: local)
        defer { try? fh.close() }
        var done = offset
        try retrying {
            if offset > 0 {
                try fh.seek(toOffset: offset)
                let r = try command("REST \(offset)")
                try ok(r, 300...399)
            } else {
                try fh.truncate(atOffset: 0)
            }
            try transferIn("RETR " + remote, path: remote) { chunk in
                fh.write(chunk)
                done += UInt64(chunk.count)
                return progress(done)
            }
        }
    }

    public func upload(_ local: URL, to remote: String, progress: ProgressHandler) throws {
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        try retrying {
            try input.seek(toOffset: 0)
            let ch = try openData()
            defer { ch.close() }
            let r = try command("STOR " + remote)
            guard r.code == 150 || r.code == 125 else { try ok(r, 100...199, remote); return }
            let d = try ch.connected()
            try dataTLS(d)
            var done: UInt64 = 0
            while true {
                let chunk = input.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                try d.write(chunk)
                done += UInt64(chunk.count)
                if !progress(done) {
                    d.close()
                    _ = try? command("ABOR")
                    _ = try? reply()
                    throw RemoteError.cancelled
                }
            }
            d.close()
            try ok(try reply(), 200...299, remote)
        }
    }

    public func makeDirectory(_ path: String) throws { try retrying { try ok(try command("MKD " + path), 200...299, path) } }
    public func removeFile(_ path: String) throws { try retrying { try ok(try command("DELE " + path), 200...299, path) } }
    public func removeDirectory(_ path: String) throws { try retrying { try ok(try command("RMD " + path), 200...299, path) } }
    public func rename(_ from: String, to: String) throws {
        try retrying {
            try ok(try command("RNFR " + from), 300...399, from)
            try ok(try command("RNTO " + to), 200...299, to)
        }
    }
    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try retrying { try ok(try command("SITE CHMOD \(String(mode, radix: 8)) \(path)"), 200...299, path) }
    }
    public func setModificationTime(_ path: String, _ date: Date) throws {
        guard features.contains("MFMT") else { return }
        try retrying { try ok(try command("MFMT \(ListParser.formatMDTM(date)) \(path)"), 200...299, path) }
    }
    public func runCommand(_ cmd: String, in directory: String) throws -> String {
        try retrying {
            _ = try command("CWD " + directory)
            return try command(cmd).text
        }
    }

    public func close() {
        if ctrl != nil { _ = try? command("QUIT") }
        ctrl?.close()
        ctrl = nil
    }

    deinit { ctrl?.close() }
}

/// ブロッキングで読み書きする TCP 接続 (途中から TLS にできる)
final class FTPStream {
    static let closedCode = -1000
    let input: InputStream
    let output: OutputStream
    private var buffer = Data()
    var timeout: TimeInterval = 60

    init(host: String, port: Int, timeout: TimeInterval = 60, family: Int32 = AF_UNSPEC, socks: FTPClient.SOCKSProxy? = nil) throws {
        self.timeout = timeout
        var i: InputStream?, o: OutputStream?
        // IP バージョンの指定があれば、先にそのアドレスを引いておく (SOCKS のときはプロキシに任せる)
        var target = host
        if family != AF_UNSPEC && socks == nil {
            guard let a = FTPStream.resolve(host, family: family) else {
                throw RemoteError("\(host) の\(family == AF_INET ? "IPv4" : "IPv6") アドレスが見つかりません")
            }
            target = a
        }
        Stream.getStreamsToHost(withName: target, port: port, inputStream: &i, outputStream: &o)
        guard let ii = i, let oo = o else { throw RemoteError("\(host):\(port) に接続できません") }
        input = ii; output = oo
        if let p = socks {
            var cfg: [String: Any] = [
                kCFStreamPropertySOCKSProxyHost as String: p.host,
                kCFStreamPropertySOCKSProxyPort as String: p.port,
                kCFStreamPropertySOCKSVersion as String: p.version == 4 ? kCFStreamSocketSOCKSVersion4 : kCFStreamSocketSOCKSVersion5,
            ]
            if !p.user.isEmpty { cfg[kCFStreamPropertySOCKSUser as String] = p.user }
            if !p.password.isEmpty { cfg[kCFStreamPropertySOCKSPassword as String] = p.password }
            input.setProperty(cfg, forKey: .socksProxyConfigurationKey)
            output.setProperty(cfg, forKey: .socksProxyConfigurationKey)
        }
        try openAndWait("\(host):\(port)")
    }

    /// 受け入れたソケットから作る (アクティブ モードのデータ接続)
    init(socket fd: Int32, timeout: TimeInterval) throws {
        self.timeout = timeout
        var r: Unmanaged<CFReadStream>?, w: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &r, &w)
        guard let rr = r?.takeRetainedValue(), let ww = w?.takeRetainedValue() else { Darwin.close(fd); throw RemoteError("データ接続を作れません") }
        input = rr as InputStream; output = ww as OutputStream
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        try openAndWait("データ接続")
    }

    static func resolve(_ host: String, family: Int32) -> String? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }

    /// この接続の自分側のアドレス
    func localAddress() -> (family: Int32, ip: String)? {
        guard let d = CFReadStreamCopyProperty(input as CFReadStream, .socketNativeHandle) as? Data,
              d.count >= MemoryLayout<CFSocketNativeHandle>.size else { return nil }
        let fd = d.withUnsafeBytes { $0.load(as: CFSocketNativeHandle.self) }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &ss) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard ok == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &ss) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) }
        }
        guard r == 0 else { return nil }
        var ip = String(cString: buf)
        // IPv4 射影アドレス (::ffff:1.2.3.4) は IPv4 として扱う
        if ip.hasPrefix("::ffff:"), ip.contains(".") { return (AF_INET, String(ip.dropFirst(7))) }
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
        return (Int32(ss.ss_family), ip)
    }

    private func openAndWait(_ name: String) throws {
        input.open(); output.open()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if input.streamStatus == .error || output.streamStatus == .error {
                let e = input.streamError ?? output.streamError
                throw RemoteError("\(name) に接続できません\n\n\(e?.localizedDescription ?? "")")
            }
            if output.streamStatus == .open && input.streamStatus == .open && (output.hasSpaceAvailable || input.hasBytesAvailable) { break }
            if Date() > deadline { close(); throw RemoteError("\(name) への接続がタイムアウトしました") }
            usleep(5000)
        }
    }

    /// TLS を始める。sessionID が同じ接続どうしは TLS セッションを使い回す
    /// (FTPS のデータ接続でセッションの再利用を求めるサーバーが多い)
    func startTLS(host: String, sessionID: String, minTLS: Int = 12, maxTLS: Int = 13) throws {
        let settings: [String: Any] = [
            kCFStreamSSLValidatesCertificateChain as String: false,
            kCFStreamSSLPeerName as String: host,
        ]
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        input.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        output.setProperty(settings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        if let ctxAny = CFReadStreamCopyProperty(input as CFReadStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) {
            let ctx = ctxAny as! SSLContext
            let id = Array(sessionID.utf8)
            _ = SSLSetPeerID(ctx, id, id.count)
            // TLS の最小/最大バージョン (WinSCP の TLS/SSL のページ)
            func proto(_ v: Int) -> SSLProtocol {
                switch v { case ...10: return .tlsProtocol1; case 11: return .tlsProtocol11; case 12: return .tlsProtocol12; default: return .tlsProtocol13 }
            }
            _ = SSLSetProtocolVersionMin(ctx, proto(minTLS))
            if maxTLS < 13 { _ = SSLSetProtocolVersionMax(ctx, proto(maxTLS)) }
        }
    }

    func peerTrust() -> SecTrust? {
        // 握手が終わるまで待つ
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let t = output.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)) {
                return (t as! SecTrust)
            }
            if output.streamStatus == .error || input.streamStatus == .error { return nil }
            if output.hasSpaceAvailable || input.hasBytesAvailable {
                if let t = input.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)) {
                    return (t as! SecTrust)
                }
            }
            usleep(5000)
        }
        return nil
    }

    private func streamFailure(_ s: Stream) -> RemoteError {
        if let e = s.streamError { return RemoteError("通信エラー: \(e.localizedDescription)", code: FTPStream.closedCode) }
        return RemoteError("接続が切れました", code: FTPStream.closedCode)
    }

    func write(_ s: String) throws { try write(Data(s.utf8)) }

    func write(_ d: Data) throws {
        var off = 0
        let deadline = Date().addingTimeInterval(timeout)
        while off < d.count {
            if output.streamStatus == .error || output.streamStatus == .closed || output.streamStatus == .atEnd {
                throw streamFailure(output)
            }
            if !output.hasSpaceAvailable {
                if Date() > deadline { throw RemoteError("送信がタイムアウトしました", code: FTPStream.closedCode) }
                usleep(1000); continue
            }
            let n = d.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress! + off, maxLength: d.count - off) }
            if n < 0 { throw streamFailure(output) }
            off += n
        }
    }

    /// 何か届くまで待って読む。終わりなら空
    func read(max: Int) throws -> Data {
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            let d = buffer.prefix(n)
            buffer.removeFirst(n)
            return Data(d)
        }
        return try rawRead(max: max)
    }

    private func rawRead(max: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            switch input.streamStatus {
            case .atEnd, .closed: return Data()
            case .error: throw streamFailure(input)
            default: break
            }
            if input.hasBytesAvailable {
                let n = input.read(&buf, maxLength: max)
                if n > 0 { return Data(buf[0..<n]) }
                if n == 0 { return Data() }
                throw streamFailure(input)
            }
            if Date() > deadline { throw RemoteError("応答がタイムアウトしました", code: FTPStream.closedCode) }
            usleep(1000)
        }
    }

    func readLine() throws -> String {
        while true {
            if let r = buffer.firstIndex(of: 0x0a) {
                var line = buffer[buffer.startIndex..<r]
                if line.last == 0x0d { line = line.dropLast() }
                buffer.removeSubrange(buffer.startIndex...r)
                return String(data: line, encoding: .utf8) ?? String(data: line, encoding: .shiftJIS) ?? String(decoding: line, as: UTF8.self)
            }
            let d = try rawRead(max: 8192)
            if d.isEmpty {
                throw RemoteError("接続が切れました", code: FTPStream.closedCode)
            }
            buffer.append(d)
        }
    }

    func close() {
        input.close()
        output.close()
    }
}

/// データ接続 (パッシブなら接続済み、アクティブなら待ち受け中)
final class FTPDataChannel {
    private var stream: FTPStream?
    private var listenFD: Int32 = -1
    private(set) var listenPort = 0
    private var timeout: TimeInterval = 60

    init(stream: FTPStream) { self.stream = stream }

    /// 自分のアドレスの空いているポートで待ち受ける
    init(listenOn local: (family: Int32, ip: String), timeout: TimeInterval) throws {
        self.timeout = timeout
        let fd = socket(local.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw RemoteError("待ち受けのソケットを作れません") }
        var ok: Int32 = -1
        if local.family == AF_INET {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = 0
            inet_pton(AF_INET, local.ip, &a.sin_addr)
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        } else {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = 0
            inet_pton(AF_INET6, local.ip, &a.sin6_addr)
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        guard ok == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw RemoteError("アクティブ モードで待ち受けできません (\(String(cString: strerror(errno))))") }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port: UInt16 = withUnsafePointer(to: &ss) { p in
            local.family == AF_INET
                ? p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
                : p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port }
        }
        listenFD = fd
        listenPort = Int(UInt16(bigEndian: port))
    }

    /// つながったデータ接続 (アクティブなら、サーバーからの接続を待つ)
    func connected() throws -> FTPStream {
        if let s = stream { return s }
        var p = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { throw RemoteError("サーバーからのデータ接続がありません (アクティブ モード)") }
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { throw RemoteError("データ接続を受け付けられません") }
        Darwin.close(listenFD)
        listenFD = -1
        let s = try FTPStream(socket: c, timeout: timeout)
        stream = s
        return s
    }

    func close() {
        stream?.close()
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
    }

    deinit { close() }
}
