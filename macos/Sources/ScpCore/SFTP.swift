import Foundation

/// SFTP (バージョン 3) のクライアント。パイプの向こうの sftp-server と話す。
/// 読み込みは専用スレッドで行い、要求ごとに ID で返事を受け取る (複数の要求を同時に出せる)。
public final class SFTPClient: RemoteFileSystem {
    public var protocolName: String { "SFTP" }

    enum T: UInt8 {
        case INIT = 1, VERSION = 2, OPEN = 3, CLOSE = 4, READ = 5, WRITE = 6, LSTAT = 7, FSTAT = 8,
             SETSTAT = 9, FSETSTAT = 10, OPENDIR = 11, READDIR = 12, REMOVE = 13, MKDIR = 14, RMDIR = 15,
             REALPATH = 16, STAT = 17, RENAME = 18, READLINK = 19, SYMLINK = 20,
             STATUS = 101, HANDLE = 102, DATA = 103, NAME = 104, ATTRS = 105,
             EXTENDED = 200, EXTENDED_REPLY = 201
    }

    struct Reply {
        var type: UInt8
        var body: Data   // ID の後ろ
    }

    final class Pending {
        let sem = DispatchSemaphore(value: 0)
        var reply: Reply?
    }

    private let inFD: Int32     // こちらから書く
    private let outFD: Int32    // こちらが読む
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var pending: [UInt32: Pending] = [:]
    private var nextID: UInt32 = 1
    private var dead: String?
    public private(set) var extensions: [String: String] = [:]
    /// 後始末 (ssh プロセスなど)
    private var onClose: (() -> Void)?
    private var errorText: () -> String = { "" }

    /// fd を直接わたす (テストで sftp-server を直接動かすときなど)
    public init(writeFD: Int32, readFD: Int32, onClose: (() -> Void)? = nil, errorText: (() -> String)? = nil) throws {
        inFD = writeFD; outFD = readFD
        self.onClose = onClose
        if let e = errorText { self.errorText = e }
        signal(SIGPIPE, SIG_IGN)
        // INIT → VERSION
        var p = Data(); p.appendU8(T.INIT.rawValue); p.appendU32(3)
        try sendRaw(p)
        guard let (type, body) = readPacket(), type == T.VERSION.rawValue else {
            let e = self.errorText().trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError(e.isEmpty ? "SFTP サーバーが応答しません" : SSHSession.friendly(e))
        }
        var r = Reader(body)
        _ = r.u32()
        while !r.atEnd, let n = r.string(), let v = r.string() { extensions[n] = v }
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "sftp-reader"
        t.start()
    }

    /// プロセス (sftp-server や ssh -s sftp) を起動してつなぐ
    public static func start(process p: Process) throws -> SFTPClient {
        let toServer = Pipe(), fromServer = Pipe(), err = Pipe()
        p.standardInput = toServer
        p.standardOutput = fromServer
        p.standardError = err
        let errLock = NSLock()
        var errText = ""
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errLock.lock(); errText += String(decoding: d, as: UTF8.self); errLock.unlock()
        }
        do { try p.run() } catch { throw RemoteError("SFTP を開始できません: \(error.localizedDescription)") }
        let w = toServer.fileHandleForWriting.fileDescriptor
        let r = fromServer.fileHandleForReading.fileDescriptor
        return try SFTPClient(writeFD: w, readFD: r, onClose: {
            try? toServer.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }, errorText: { errLock.lock(); defer { errLock.unlock() }; return errText })
    }

    // MARK: 低レベル

    private func sendRaw(_ payload: Data) throws {
        var pkt = Data(); pkt.appendU32(UInt32(payload.count)); pkt.append(payload)
        writeLock.lock(); defer { writeLock.unlock() }
        if !writeAll(inFD, pkt) { throw RemoteError("接続が切れました") }
    }

    private func readPacket() -> (UInt8, Data)? {
        guard let h = readExact(outFD, 4) else { return nil }
        let len = Int(h.readU32(at: 0))
        guard len >= 1, len < 1 << 26, let d = readExact(outFD, len) else { return nil }
        return (d[d.startIndex], d.subdata(in: (d.startIndex + 1)..<d.endIndex))
    }

    private func readLoop() {
        while let (type, body) = readPacket() {
            guard body.count >= 4 else { continue }
            let id = body.readU32(at: 0)
            lock.lock()
            let p = pending.removeValue(forKey: id)
            lock.unlock()
            if let p = p {
                p.reply = Reply(type: type, body: body.subdata(in: (body.startIndex + 4)..<body.endIndex))
                p.sem.signal()
            }
        }
        lock.lock()
        let msg = errorText().trimmingCharacters(in: .whitespacesAndNewlines)
        dead = msg.isEmpty ? "接続が切れました" : "接続が切れました\n\n" + msg
        let all = pending
        pending = [:]
        lock.unlock()
        for p in all.values { p.sem.signal() }
    }

    /// 要求を出す (返事は待たない)
    private func request(_ type: T, _ build: (inout Data) -> Void) throws -> Pending {
        let p = Pending()
        lock.lock()
        if let d = dead { lock.unlock(); throw RemoteError(d) }
        let id = nextID; nextID &+= 1
        pending[id] = p
        lock.unlock()
        var d = Data(); d.appendU8(type.rawValue); d.appendU32(id)
        build(&d)
        try sendRaw(d)
        return p
    }

    private func wait(_ p: Pending) throws -> Reply {
        p.sem.wait()
        if let r = p.reply { return r }
        lock.lock(); let d = dead; lock.unlock()
        throw RemoteError(d ?? "接続が切れました")
    }

    private func call(_ type: T, _ build: (inout Data) -> Void) throws -> Reply {
        try wait(try request(type, build))
    }

    static let statusMessages: [UInt32: String] = [
        1: "ファイルの終わり", 2: "ファイルがありません", 3: "アクセスが拒否されました", 4: "失敗しました",
        5: "不正なメッセージ", 6: "接続がありません", 7: "接続が切れました", 8: "サポートされていない操作です",
    ]

    private func statusError(_ r: Reply, _ path: String) -> RemoteError {
        var rd = Reader(r.body)
        let code = rd.u32() ?? 4
        let msg = rd.string() ?? ""
        let base = SFTPClient.statusMessages[code] ?? "エラー \(code)"
        let text = msg.isEmpty || msg.lowercased() == "failure" ? base : "\(base) (\(msg))"
        return RemoteError(path.isEmpty ? text : "\(path): \(text)", code: Int(code))
    }

    private func expectStatusOK(_ r: Reply, _ path: String) throws {
        guard r.type == T.STATUS.rawValue else { throw RemoteError("予期しない応答") }
        var rd = Reader(r.body)
        if rd.u32() != 0 { throw statusError(r, path) }
    }

    private func expectHandle(_ r: Reply, _ path: String) throws -> Data {
        if r.type == T.STATUS.rawValue { throw statusError(r, path) }
        guard r.type == T.HANDLE.rawValue else { throw RemoteError("予期しない応答") }
        var rd = Reader(r.body)
        guard let h = rd.bytes() else { throw RemoteError("予期しない応答") }
        return h
    }

    private func closeHandle(_ h: Data) {
        _ = try? call(.CLOSE) { $0.appendBytes(h) }
    }

    // MARK: 属性

    struct Attrs {
        var size: UInt64?
        var uid: UInt32?, gid: UInt32?
        var perm: UInt32?
        var atime: UInt32?, mtime: UInt32?
    }

    static func parseAttrs(_ r: inout Reader) -> Attrs {
        var a = Attrs()
        let flags = r.u32() ?? 0
        if flags & 1 != 0 { a.size = r.u64() }
        if flags & 2 != 0 { a.uid = r.u32(); a.gid = r.u32() }
        if flags & 4 != 0 { a.perm = r.u32() }
        if flags & 8 != 0 { a.atime = r.u32(); a.mtime = r.u32() }
        if flags & 0x8000_0000 != 0 {
            let n = r.u32() ?? 0
            for _ in 0..<n { _ = r.string(); _ = r.string() }
        }
        return a
    }

    static func entry(name: String, longname: String, attrs a: Attrs) -> FileEntry {
        let mode = a.perm ?? 0
        let type = mode & 0o170000
        // longname は "drwxr-xr-x  2 user group ..." の形。所有者とグループを取り出す
        let cols = longname.split(separator: " ", omittingEmptySubsequences: true)
        let owner = cols.count > 3 ? String(cols[2]) : (a.uid.map(String.init) ?? "")
        let group = cols.count > 3 ? String(cols[3]) : (a.gid.map(String.init) ?? "")
        return FileEntry(name: name, isDirectory: type == 0o040000, isSymlink: type == 0o120000,
                         size: a.size ?? 0, mtime: a.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                         permissions: a.perm.map { $0 & 0o7777 }, owner: owner, group: group)
    }

    // MARK: RemoteFileSystem

    public func homeDirectory() throws -> String { try realpath(".") }

    public func realpath(_ path: String) throws -> String {
        let r = try call(.REALPATH) { $0.appendString(path) }
        if r.type == T.STATUS.rawValue { throw statusError(r, path) }
        var rd = Reader(r.body)
        guard rd.u32() ?? 0 >= 1, let name = rd.string() else { throw RemoteError("予期しない応答") }
        return name
    }

    public func list(_ path: String) throws -> [FileEntry] {
        let h = try expectHandle(try call(.OPENDIR) { $0.appendString(path) }, path)
        defer { closeHandle(h) }
        var out: [FileEntry] = []
        while true {
            let r = try call(.READDIR) { $0.appendBytes(h) }
            if r.type == T.STATUS.rawValue {
                var rd = Reader(r.body)
                if rd.u32() == 1 { break }
                throw statusError(r, path)
            }
            guard r.type == T.NAME.rawValue else { throw RemoteError("予期しない応答") }
            var rd = Reader(r.body)
            let n = rd.u32() ?? 0
            for _ in 0..<n {
                guard let name = rd.string(), let long = rd.string() else { break }
                let a = SFTPClient.parseAttrs(&rd)
                if name == "." || name == ".." { continue }
                out.append(SFTPClient.entry(name: name, longname: long, attrs: a))
            }
        }
        // シンボリックリンクは行き先を調べて、ディレクトリかどうかを決める
        for i in out.indices where out[i].isSymlink {
            let full = RemotePath.join(path, out[i].name)
            if let t = try? stat(full) {
                out[i].isDirectory = t.isDirectory
                if !t.isDirectory { out[i].size = t.size }
            }
            if let r = try? call(.READLINK, { $0.appendString(full) }), r.type == T.NAME.rawValue {
                var rd = Reader(r.body); _ = rd.u32(); out[i].linkTarget = rd.string()
            }
        }
        return out
    }

    public func stat(_ path: String) throws -> FileEntry {
        let r = try call(.STAT) { $0.appendString(path) }
        if r.type == T.STATUS.rawValue { throw statusError(r, path) }
        var rd = Reader(r.body)
        let a = SFTPClient.parseAttrs(&rd)
        return SFTPClient.entry(name: RemotePath.name(path), longname: "", attrs: a)
    }

    static let chunk = 32768
    static let window = 32

    public func download(_ remote: String, to local: URL, offset: UInt64, progress: ProgressHandler) throws {
        let h = try expectHandle(try call(.OPEN) { d in
            d.appendString(remote); d.appendU32(1); d.appendU32(0)
        }, remote)
        defer { closeHandle(h) }
        if offset == 0 || !FileManager.default.fileExists(atPath: local.path) {
            guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
                throw RemoteError("\(local.path): ファイルを作れません")
            }
        }
        let fh = try FileHandle(forWritingTo: local)
        defer { try? fh.close() }
        if offset == 0 { try fh.truncate(atOffset: 0) }

        var queue: [(Pending, UInt64, Int)] = []
        var next = offset
        var eof = false
        var done = offset
        func issue(_ off: UInt64, _ len: Int) throws {
            let p = try request(.READ) { d in d.appendBytes(h); d.appendU64(off); d.appendU32(UInt32(len)) }
            queue.append((p, off, len))
        }
        while true {
            while !eof && queue.count < SFTPClient.window {
                try issue(next, SFTPClient.chunk)
                next += UInt64(SFTPClient.chunk)
            }
            if queue.isEmpty { break }
            let (p, off, len) = queue.removeFirst()
            let r = try wait(p)
            if r.type == T.STATUS.rawValue {
                var rd = Reader(r.body)
                if rd.u32() == 1 { eof = true; continue }
                drain(queue.map { $0.0 })
                throw statusError(r, remote)
            }
            guard r.type == T.DATA.rawValue else { throw RemoteError("予期しない応答") }
            var rd = Reader(r.body)
            guard let data = rd.bytes() else { throw RemoteError("予期しない応答") }
            if !data.isEmpty {
                try fh.seek(toOffset: off)
                fh.write(data)
                done += UInt64(data.count)
            }
            // 頼んだより短かったら残りをもう一度頼む
            if data.count < len && !data.isEmpty && !eof { try issue(off + UInt64(data.count), len - data.count) }
            if !progress(done) {
                drain(queue.map { $0.0 })
                throw RemoteError.cancelled
            }
        }
    }

    public func upload(_ local: URL, to remote: String, progress: ProgressHandler) throws {
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let h = try expectHandle(try call(.OPEN) { d in
            d.appendString(remote); d.appendU32(0x02 | 0x08 | 0x10); d.appendU32(0)
        }, remote)
        defer { closeHandle(h) }
        var queue: [Pending] = []
        var off: UInt64 = 0
        var acked: UInt64 = 0
        var sizes: [Int] = []
        var finished = false
        while true {
            while !finished && queue.count < SFTPClient.window {
                let data = input.readData(ofLength: SFTPClient.chunk)
                if data.isEmpty { finished = true; break }
                let o = off
                queue.append(try request(.WRITE) { d in d.appendBytes(h); d.appendU64(o); d.appendBytes(data) })
                sizes.append(data.count)
                off += UInt64(data.count)
            }
            if queue.isEmpty { break }
            let p = queue.removeFirst()
            let n = sizes.removeFirst()
            let r = try wait(p)
            do { try expectStatusOK(r, remote) } catch { drain(queue); throw error }
            acked += UInt64(n)
            if !progress(acked) { drain(queue); throw RemoteError.cancelled }
        }
    }

    /// 出した要求の返事を捨てる
    private func drain(_ ps: [Pending]) { for p in ps { _ = try? wait(p) } }

    public func makeDirectory(_ path: String) throws {
        try expectStatusOK(try call(.MKDIR) { d in d.appendString(path); d.appendU32(0) }, path)
    }
    public func removeFile(_ path: String) throws {
        try expectStatusOK(try call(.REMOVE) { $0.appendString(path) }, path)
    }
    public func removeDirectory(_ path: String) throws {
        try expectStatusOK(try call(.RMDIR) { $0.appendString(path) }, path)
    }
    public func rename(_ from: String, to: String) throws {
        if extensions["posix-rename@openssh.com"] != nil {
            try expectStatusOK(try call(.EXTENDED) { d in
                d.appendString("posix-rename@openssh.com"); d.appendString(from); d.appendString(to)
            }, from)
        } else {
            try expectStatusOK(try call(.RENAME) { d in d.appendString(from); d.appendString(to) }, from)
        }
    }
    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try expectStatusOK(try call(.SETSTAT) { d in d.appendString(path); d.appendU32(4); d.appendU32(mode) }, path)
    }
    public func setModificationTime(_ path: String, _ date: Date) throws {
        let t = UInt32(max(0, date.timeIntervalSince1970))
        try expectStatusOK(try call(.SETSTAT) { d in d.appendString(path); d.appendU32(8); d.appendU32(t); d.appendU32(t) }, path)
    }

    /// SSH で使っているときは、コマンドを別の相乗り接続で実行できる
    public var commandRunner: ((String, String) throws -> String)?
    public func runCommand(_ command: String, in directory: String) throws -> String {
        guard let r = commandRunner else { throw RemoteError("このセッションではコマンドを実行できません") }
        return try r(command, directory)
    }

    public func close() {
        onClose?()
        onClose = nil
    }

    deinit { close() }
}

/// SFTP のメッセージを読む
struct Reader {
    let d: Data
    var i: Int
    init(_ d: Data) { self.d = d; i = d.startIndex }
    var atEnd: Bool { i >= d.endIndex }
    mutating func u8() -> UInt8? { guard i < d.endIndex else { return nil }; defer { i += 1 }; return d[i] }
    mutating func u32() -> UInt32? {
        guard i + 4 <= d.endIndex else { return nil }
        defer { i += 4 }
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
    mutating func u64() -> UInt64? {
        guard let a = u32(), let b = u32() else { return nil }
        return UInt64(a) << 32 | UInt64(b)
    }
    mutating func bytes() -> Data? {
        guard let n = u32(), i + Int(n) <= d.endIndex else { return nil }
        defer { i += Int(n) }
        return d.subdata(in: i..<(i + Int(n)))
    }
    mutating func string() -> String? {
        guard let b = bytes() else { return nil }
        return String(decoding: b, as: UTF8.self)
    }
}
