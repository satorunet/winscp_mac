import Foundation

/// ssh のパスワードやホスト鍵の確認を GUI で答えるしくみ。
///
/// ssh に SSH_ASKPASS=<このアプリ> と SSH_ASKPASS_REQUIRE=force を渡すと、ssh は質問のたびに
/// このアプリを「askpass モード」で起動する。askpass モードのアプリは UNIX ソケットで本体に
/// 質問を送り、本体が出したダイアログの答えを標準出力に書いて終わる。
public enum Askpass {
    public static let socketEnv = "WINSCPMAC_ASKPASS_SOCK"

    /// askpass として起動されたなら、質問を本体に渡して答えを出力し、プロセスを終える。
    /// main の一番最初に呼ぶ。
    public static func runHelperIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env[socketEnv], env["SSH_ASKPASS"] != nil else { return }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, connectUnix(fd, path) else { exit(1) }
        var msg = Data()
        let p = Data(prompt.utf8)
        msg.appendU32(UInt32(p.count)); msg.append(p)
        guard writeAll(fd, msg) else { exit(1) }
        guard let head = readExact(fd, 5) else { exit(1) }
        let ok = head[0] == 1
        let len = Int(head.readU32(at: 1))
        let body = len > 0 ? (readExact(fd, len) ?? Data()) : Data()
        close(fd)
        guard ok else { exit(1) }
        FileHandle.standardOutput.write(body)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }

    static func connectUnix(_ fd: Int32, _ path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }
}

/// 本体側: ソケットで質問を待ち受ける
public final class AskpassServer {
    public enum Kind { case password, hostKey, other }
    /// 質問への答え。nil ならキャンセル
    public typealias Handler = (_ prompt: String, _ kind: Kind) -> String?

    public let path: String
    private var fd: Int32 = -1
    private let handler: Handler
    private var closed = false

    public init(handler: @escaping Handler) throws {
        self.handler = handler
        path = NSTemporaryDirectory() + "wscp-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError("ソケットを作れません") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let old = umask(0o077)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard r == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw RemoteError("ソケットを作れません") }
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "askpass"
        t.start()
    }

    private func acceptLoop() {
        while !closed {
            let c = accept(fd, nil, nil)
            if c < 0 { if closed { return }; continue }
            handle(c)
        }
    }

    private func handle(_ c: Int32) {
        defer { Darwin.close(c) }
        guard let head = readExact(c, 4) else { return }
        let len = Int(head.readU32(at: 0))
        guard len < 1 << 20, let body = len > 0 ? readExact(c, len) : Data() else { return }
        let prompt = String(decoding: body, as: UTF8.self)
        let answer = handler(prompt, AskpassServer.classify(prompt))
        var out = Data([answer == nil ? 0 : 1])
        let a = Data((answer ?? "").utf8)
        out.appendU32(UInt32(a.count)); out.append(a)
        _ = writeAll(c, out)
    }

    public static func classify(_ prompt: String) -> Kind {
        let l = prompt.lowercased()
        if l.contains("(yes/no") || l.contains("continue connecting") { return .hostKey }
        if l.contains("password") || l.contains("passphrase") || l.contains("verification code") || l.contains("pin") { return .password }
        return .other
    }

    public func close() {
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(path)
    }

    deinit { close() }
}

// MARK: - 小さな道具

func readExact(_ fd: Int32, _ n: Int) -> Data? {
    var d = Data(count: n)
    var got = 0
    while got < n {
        let r = d.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { return nil }
        got += r
    }
    return d
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var off = 0
    while off < data.count {
        let r = data.withUnsafeBytes { write(fd, $0.baseAddress! + off, data.count - off) }
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { return false }
        off += r
    }
    return true
}

extension Data {
    mutating func appendU8(_ v: UInt8) { append(v) }
    mutating func appendU32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
    mutating func appendU64(_ v: UInt64) { appendU32(UInt32(v >> 32)); appendU32(UInt32(v & 0xffff_ffff)) }
    mutating func appendString(_ s: String) { let d = Data(s.utf8); appendU32(UInt32(d.count)); append(d) }
    mutating func appendBytes(_ d: Data) { appendU32(UInt32(d.count)); append(d) }
    func readU32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3])
    }
}
