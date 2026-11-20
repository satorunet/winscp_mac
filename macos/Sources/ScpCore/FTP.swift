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
        public init(host: String, port: Int = 21, user: String = "", password: String = "", security: FTPSecurity = .none, passive: Bool = true) {
            self.host = host; self.port = port; self.user = user; self.password = password; self.security = security; self.passive = passive
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
        let s = try FTPStream(host: params.host, port: params.port)
        ctrl = s
        if security == .implicitTLS { try startTLS(s) }
        let g = try reply()
        guard g.code == 220 else { throw RemoteError("サーバーの応答: \(g.text)") }
        welcome = g.text
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
    }

    private func startTLS(_ s: FTPStream) throws {
        try s.startTLS(host: params.host, sessionID: tlsSessionID)
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

    private func openData() throws -> FTPStream {
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
            // 内部アドレスや 0.0.0.0 を返すサーバーがあるので、そういうときは接続先のホストを使う
            if !(ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("172.") || ip == "0.0.0.0" || ip.hasPrefix("127.")) {
                host = ip
            }
        }
        guard port > 0 else { throw RemoteError("データ接続のポートが分かりません") }
        return try FTPStream(host: host, port: port)
    }

    private func dataTLS(_ d: FTPStream) throws {
        if security != .none { try d.startTLS(host: params.host, sessionID: tlsSessionID); try verify(d) }
    }

    /// データ接続を開き、コマンドを送り、データを受け取る
    private func transferIn(_ cmd: String, path: String, sink: (Data) throws -> Bool) throws {
        let d = try openData()
        defer { d.close() }
        let r = try command(cmd)
        guard r.code == 150 || r.code == 125 else {
            try ok(r, 100...199, path)
            return
        }
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
            if features.contains("MLSD") {
                try transferIn("MLSD " + path, path: path) { data.append($0); return true }
                return decode(data).split(whereSeparator: { $0.isNewline }).compactMap {
                    ListParser.parseMLSDLine(String($0))
                }
            }
            let c = try command("CWD " + path)
            try ok(c, 200...299, path)
            do {
                try transferIn("LIST -a", path: path) { data.append($0); return true }
            } catch let e as RemoteError where e.code >= 500 {
                data = Data()
                try transferIn("LIST", path: path) { data.append($0); return true }
            }
            return ListParser.parseUnixList(decode(data), utc: false)
        }
    }

    public func stat(_ path: String) throws -> FileEntry {
        try retrying {
            if features.contains("MLST") {
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
            let d = try openData()
            defer { d.close() }
            let r = try command("STOR " + remote)
            guard r.code == 150 || r.code == 125 else { try ok(r, 100...199, remote); return }
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

    init(host: String, port: Int) throws {
        var i: InputStream?, o: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &i, outputStream: &o)
        guard let ii = i, let oo = o else { throw RemoteError("\(host):\(port) に接続できません") }
        input = ii; output = oo
        input.open(); output.open()
        let deadline = Date().addingTimeInterval(20)
        while true {
            if input.streamStatus == .error || output.streamStatus == .error {
                let e = input.streamError ?? output.streamError
                throw RemoteError("\(host):\(port) に接続できません\n\n\(e?.localizedDescription ?? "")")
            }
            if output.streamStatus == .open && input.streamStatus == .open && (output.hasSpaceAvailable || input.hasBytesAvailable) { break }
            if Date() > deadline { close(); throw RemoteError("\(host):\(port) への接続がタイムアウトしました") }
            usleep(5000)
        }
    }

    /// TLS を始める。sessionID が同じ接続どうしは TLS セッションを使い回す
    /// (FTPS のデータ接続でセッションの再利用を求めるサーバーが多い)
    func startTLS(host: String, sessionID: String) throws {
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
