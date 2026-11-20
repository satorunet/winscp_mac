import Foundation

/// SCP モード: WinSCP の SCP と同じく、リモートのシェルコマンド (ls, cat, mkdir, mv ...) で操作する。
/// SFTP サーバーが無いホスト向け。ssh のマスター接続に相乗りするので、パスワードは最初の 1 回だけ。
public final class SCPClient: RemoteFileSystem {
    public var protocolName: String { "SCP" }
    let ssh: SSHSession?
    /// リモートでコマンドを実行するプロセスを作る (ふつうは ssh の相乗り接続)
    let makeProcess: (String) -> Process
    private let isAlive: () -> Bool

    public init(ssh: SSHSession) {
        self.ssh = ssh
        makeProcess = { ssh.process([$0]) }
        isAlive = { ssh.isAlive }
    }

    /// テスト用: この Mac の /bin/sh でコマンドを実行する
    public init(localShell: Void) {
        ssh = nil
        makeProcess = { cmd in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            return p
        }
        isAlive = { true }
    }

    static func q(_ s: String) -> String { SSHSession.quote(s) }

    /// コマンドを実行して標準出力を返す。失敗 (終了コード != 0) なら標準エラーを添えて throw
    @discardableResult
    func run(_ cmd: String, stdin: FileHandle? = nil, stdoutTo: FileHandle? = nil,
             progress: ProgressHandler = { _ in true }) throws -> String {
        let p = makeProcess(cmd)
        let out = Pipe(), err = Pipe()
        p.standardOutput = stdoutTo ?? out
        p.standardError = err
        p.standardInput = stdin ?? FileHandle.nullDevice
        var errData = Data()
        let errLock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errLock.lock(); errData.append(d); errLock.unlock()
        }
        do { try p.run() } catch { throw RemoteError("ssh を起動できません: \(error.localizedDescription)") }
        var outData = Data()
        if let watched = stdoutTo ?? stdin {
            // 進み具合: 書いている (読んでいる) ファイルの位置を見張る
            while p.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
                if !progress(watched.offsetInFile) { p.terminate(); p.waitUntilExit(); throw RemoteError.cancelled }
            }
        }
        if stdoutTo == nil {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.02)
        errLock.lock(); let e = String(decoding: errData, as: UTF8.self); errLock.unlock()
        if p.terminationStatus != 0 {
            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isAlive() { throw RemoteError("接続が切れました" + (msg.isEmpty ? "" : "\n\n" + msg)) }
            throw RemoteError(msg.isEmpty ? "コマンドが失敗しました (終了コード \(p.terminationStatus))" : msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    public func homeDirectory() throws -> String {
        try run("pwd").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一覧のコマンド。上から順に試し、使えたものを覚えておく
    /// (GNU ls なら秒まで分かる。最小限のシェルしかないサーバーでも ls -la だけは通ることが多い)
    private static let listCommands = [
        "LC_ALL=C ls -la --time-style=+%Y-%m-%d\\ %H:%M:%S\\ %z",
        "LC_ALL=C ls -la",
        "ls -la",
    ]
    private var listCommand: Int?

    private func ls(_ args: String) throws -> String {
        if let i = listCommand { return try run("\(SCPClient.listCommands[i]) \(args)") }
        var lastError: Error = RemoteError("一覧を取得できません")
        for (i, c) in SCPClient.listCommands.enumerated() {
            do {
                let out = try run("\(c) \(args)")
                listCommand = i
                return out
            } catch { lastError = error }
        }
        throw lastError
    }

    public func list(_ path: String) throws -> [FileEntry] {
        let dir = path.hasSuffix("/") ? path : path + "/"
        var list = ListParser.parseUnixList(try ls(SCPClient.q(dir)))
        // リンク先がディレクトリかどうか (シェルが使えるときだけ)
        let links = list.indices.filter { list[$0].isSymlink }
        if !links.isEmpty {
            let names = links.map { SCPClient.q(RemotePath.join(path, list[$0].name)) }.joined(separator: " ")
            if let r = try? run("for f in \(names); do if [ -d \"$f\" ]; then echo d; else echo f; fi; done") {
                let flags = r.split(separator: "\n")
                for (k, i) in links.enumerated() where k < flags.count { list[i].isDirectory = flags[k] == "d" }
            }
        }
        return list
    }

    public func stat(_ path: String) throws -> FileEntry {
        let out = try ls("-dL \(SCPClient.q(path))")
        guard var e = ListParser.parseUnixLine(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteError("\(path): 情報を取得できません")
        }
        e.name = RemotePath.name(path)
        return e
    }

    // MARK: SCP プロトコルでの転送 (scp -f / scp -t)

    /// リモートの scp を起動して、標準入出力でやりとりする
    private final class SCPChannel {
        let p: Process
        let toRemote: Int32, fromRemote: Int32
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        private var errData = Data()
        private let lock = NSLock()

        init(_ p: Process) throws {
            self.p = p
            toRemote = inPipe.fileHandleForWriting.fileDescriptor
            fromRemote = outPipe.fileHandleForReading.fileDescriptor
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                self?.lock.lock(); self?.errData.append(d); self?.lock.unlock()
            }
            signal(SIGPIPE, SIG_IGN)
            do { try p.run() } catch { throw RemoteError("ssh を起動できません: \(error.localizedDescription)") }
        }

        var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

        func fail(_ what: String) -> RemoteError {
            Thread.sleep(forTimeInterval: 0.05)
            let e = stderrText
            return RemoteError(e.isEmpty ? what : "\(what)\n\n\(e)")
        }

        func send(_ d: Data) throws { if !writeAll(toRemote, d) { throw fail("接続が切れました") } }
        func send(_ s: String) throws { try send(Data(s.utf8)) }
        func ok() throws { try send(Data([0])) }

        func readLine() throws -> String {
            var bytes: [UInt8] = []
            while true {
                guard let b = readExact(fromRemote, 1) else { throw fail("接続が切れました") }
                if b[0] == 0x0a { break }
                bytes.append(b[0])
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// 確認の 1 バイト (0 なら OK、1/2 ならエラーの文が続く)
        func expectOK() throws {
            guard let b = readExact(fromRemote, 1) else { throw fail("接続が切れました") }
            if b[0] == 0 { return }
            let msg = (try? readLine()) ?? ""
            throw RemoteError(msg.isEmpty ? "SCP のエラー" : msg)
        }

        func finish() {
            try? inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
        }
        func kill() {
            try? inPipe.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
    }

    public func download(_ remote: String, to local: URL, offset: UInt64, progress: ProgressHandler) throws {
        let ch = try SCPChannel(makeProcess("scp -f \(SCPClient.q(remote))"))
        var finished = false
        defer { if !finished { ch.kill() } }
        try ch.ok()
        // 時刻 (T...) が来ることもあるので、C の行まで読む
        var header = ""
        while true {
            guard let b = readExact(ch.fromRemote, 1) else { throw ch.fail("\(remote): ダウンロードできません") }
            if b[0] == 1 || b[0] == 2 { throw RemoteError((try? ch.readLine()) ?? "\(remote): ダウンロードできません") }
            let rest = try ch.readLine()
            let line = String(UnicodeScalar(b[0])) + rest
            if line.hasPrefix("T") { try ch.ok(); continue }
            if line.hasPrefix("D") { throw RemoteError("\(remote): ディレクトリです") }
            header = line
            break
        }
        // C0644 <size> <name>
        let parts = header.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, header.hasPrefix("C"), let size = UInt64(parts[1]) else {
            throw RemoteError("\(remote): SCP の応答を読めません (\(header))")
        }
        guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
            throw RemoteError("\(local.path): ファイルを作れません")
        }
        let fh = try FileHandle(forWritingTo: local)
        defer { try? fh.close() }
        try ch.ok()
        var done: UInt64 = 0
        var buf = [UInt8](repeating: 0, count: 65536)
        while done < size {
            let want = Int(min(UInt64(buf.count), size - done))
            let n = read(ch.fromRemote, &buf, want)
            if n <= 0 { throw ch.fail("\(remote): 途中で切れました") }
            fh.write(Data(buf[0..<n]))
            done += UInt64(n)
            if !progress(done) { throw RemoteError.cancelled }
        }
        try ch.expectOK()
        try ch.ok()
        finished = true
        ch.finish()
    }

    public func upload(_ local: URL, to remote: String, progress: ProgressHandler) throws {
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = ((attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o777
        let ch = try SCPChannel(makeProcess("scp -t \(SCPClient.q(remote))"))
        var finished = false
        defer { if !finished { ch.kill() } }
        try ch.expectOK()
        try ch.send("C0\(String(mode, radix: 8)) \(size) \(RemotePath.name(remote))\n")
        try ch.expectOK()
        var done: UInt64 = 0
        while true {
            let d = input.readData(ofLength: 65536)
            if d.isEmpty { break }
            try ch.send(d)
            done += UInt64(d.count)
            if !progress(done) { throw RemoteError.cancelled }
        }
        try ch.ok()
        try ch.expectOK()
        finished = true
        ch.finish()
    }

    public func makeDirectory(_ path: String) throws { try run("mkdir \(SCPClient.q(path))") }
    public func removeFile(_ path: String) throws { try run("rm -f \(SCPClient.q(path))") }
    public func removeDirectory(_ path: String) throws { try run("rmdir \(SCPClient.q(path))") }
    public func rename(_ from: String, to: String) throws { try run("mv -f \(SCPClient.q(from)) \(SCPClient.q(to))") }
    public func setPermissions(_ path: String, _ mode: UInt32) throws {
        try run("chmod \(String(mode, radix: 8)) \(SCPClient.q(path))")
    }
    public func setModificationTime(_ path: String, _ date: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm.ss"
        try run("TZ=UTC touch -t \(f.string(from: date)) \(SCPClient.q(path))")
    }
    public func runCommand(_ command: String, in directory: String) throws -> String {
        try run("cd \(SCPClient.q(directory)) && { \(command)\n} 2>&1")
    }
    public func close() { ssh?.close() }
}

/// SSH の接続を作り、SFTP か SCP のファイルシステムを返す
public enum SSHConnector {
    public static func connect(_ params: SSHParams, protocol proto: FileProtocol, askpassProgram: String,
                               handler: @escaping AskpassServer.Handler,
                               sessionCreated: ((SSHSession) -> Void)? = nil) throws -> RemoteFileSystem {
        let ssh = try SSHSession(params, askpassProgram: askpassProgram, handler: handler)
        sessionCreated?(ssh)
        if proto == .scp { return SCPClient(ssh: ssh) }
        do {
            let c = try SFTPClient.start(process: ssh.process(["sftp"], subsystem: true))
            let scp = SCPClient(ssh: ssh)
            c.commandRunner = { cmd, dir in try scp.runCommand(cmd, in: dir) }
            return SFTPOverSSH(sftp: c, ssh: ssh)
        } catch {
            ssh.close()
            throw error
        }
    }
}

/// SFTP クライアントと、その下の ssh 接続をまとめて閉じるための入れ物
public final class SFTPOverSSH: RemoteFileSystem {
    public let sftp: SFTPClient
    public let ssh: SSHSession
    init(sftp: SFTPClient, ssh: SSHSession) { self.sftp = sftp; self.ssh = ssh }
    public var protocolName: String { "SFTP" }
    public func homeDirectory() throws -> String { try sftp.homeDirectory() }
    public func list(_ path: String) throws -> [FileEntry] { try sftp.list(path) }
    public func stat(_ path: String) throws -> FileEntry { try sftp.stat(path) }
    public func download(_ remote: String, to local: URL, offset: UInt64, progress: ProgressHandler) throws {
        try sftp.download(remote, to: local, offset: offset, progress: progress)
    }
    public func upload(_ local: URL, to remote: String, progress: ProgressHandler) throws {
        try sftp.upload(local, to: remote, progress: progress)
    }
    public func makeDirectory(_ path: String) throws { try sftp.makeDirectory(path) }
    public func removeFile(_ path: String) throws { try sftp.removeFile(path) }
    public func removeDirectory(_ path: String) throws { try sftp.removeDirectory(path) }
    public func rename(_ from: String, to: String) throws { try sftp.rename(from, to: to) }
    public func setPermissions(_ path: String, _ mode: UInt32) throws { try sftp.setPermissions(path, mode) }
    public func setModificationTime(_ path: String, _ date: Date) throws { try sftp.setModificationTime(path, date) }
    public func runCommand(_ command: String, in directory: String) throws -> String { try sftp.runCommand(command, in: directory) }
    public func close() { sftp.close(); ssh.close() }
}
