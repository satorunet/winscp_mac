import Foundation

/// SSH の接続先
public struct SSHParams {
    public var host: String
    public var port: Int
    public var user: String
    public var keyFile: String
    /// ssh にそのまま渡す追加の引数 (-o ... など)。ssh は同じオプションなら先に書いたものを使うので、既定の値より前に置く
    public var extraArgs: [String]
    /// エージェントの転送を許す (WinSCP の「エージェントの転送を許可する」)
    public var forwardAgent = false
    /// SFTP サーバーのコマンド (空ならサブシステム "sftp")
    public var sftpServer = ""
    /// SFTP を始められなかったら SCP にする (WinSCP の「SCP へのフォールバックを許可する」)
    public var scpFallback = false
    public init(host: String, port: Int = 22, user: String = "", keyFile: String = "", extraArgs: [String] = []) {
        self.host = host; self.port = port; self.user = user; self.keyFile = keyFile; self.extraArgs = extraArgs
    }

    /// サイトの設定から作ったオプションを足す
    public mutating func apply(_ o: SSHOptionSet) {
        extraArgs += o.args
        forwardAgent = o.forwardAgent
        sftpServer = o.sftpServer
        scpFallback = o.scpFallback
    }
}

/// macOS の /usr/bin/ssh を使った接続。
/// まず「マスター」を 1 本つないで認証し (ControlMaster)、SFTP やコマンドはその接続に相乗りさせる。
/// こうすると、パスワードを聞くのは最初の 1 回だけになる。
public final class SSHSession {
    public static var sshPath = "/usr/bin/ssh"

    public let params: SSHParams
    public let controlPath: String
    private let master = Process()
    private let errLock = NSLock()
    private var errText = ""
    private var askpass: AskpassServer?
    private var cancelled = false

    /// 接続して認証が済むまで待つ (失敗したら throw)。
    /// askpassProgram: 質問に答えるプログラム (ふつうはこのアプリ自身)。
    public init(_ params: SSHParams, askpassProgram: String, handler: @escaping AskpassServer.Handler) throws {
        self.params = params
        controlPath = NSTemporaryDirectory() + "wscp-\(UUID().uuidString.prefix(8)).ctl"
        let ask = try AskpassServer(handler: handler)
        askpass = ask

        master.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        master.arguments = ["-M", "-S", controlPath, "-o", "ControlPersist=no", "-N", "-T", "-x"] + (params.forwardAgent ? [] : ["-a"]) +
                           ["-o", "NumberOfPasswordPrompts=3"] + baseArgs() + [params.host]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpassProgram
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[Askpass.socketEnv] = ask.path
        master.environment = env
        master.standardInput = FileHandle.nullDevice
        master.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        master.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self = self, !d.isEmpty else { h.readabilityHandler = nil; return }
            self.errLock.lock(); self.errText += String(decoding: d, as: UTF8.self); self.errLock.unlock()
        }
        do { try master.run() } catch { ask.close(); throw RemoteError("ssh を起動できません: \(error.localizedDescription)") }

        // 認証が終わってマスターが使えるようになるまで待つ
        while true {
            if cancelled { close(); throw RemoteError.cancelled }
            if !master.isRunning {
                master.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.1)
                let msg = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                ask.close()
                throw RemoteError(msg.isEmpty ? "接続できませんでした" : SSHSession.friendly(msg))
            }
            if FileManager.default.fileExists(atPath: controlPath), check() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    public var stderrText: String {
        errLock.lock(); defer { errLock.unlock() }
        return errText
    }

    /// ssh のよくあるエラーをわかりやすく
    static func friendly(_ msg: String) -> String {
        let lines = msg.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty
        }
        let s = lines.joined(separator: "\n")
        if s.contains("Permission denied") { return "認証に失敗しました。\n\n" + s }
        if s.contains("Host key verification failed") { return "ホスト鍵を確認できなかったため、接続を中止しました。\n\n" + s }
        if s.contains("Could not resolve hostname") { return "ホスト名が見つかりません。\n\n" + s }
        if s.contains("Connection refused") { return "接続を拒否されました。\n\n" + s }
        if s.contains("timed out") { return "接続がタイムアウトしました。\n\n" + s }
        return s
    }

    func baseArgs() -> [String] {
        // ssh は同じオプションなら最初の値を使うので、サイトの設定 (extraArgs) を先に、既定の値を後に置く
        var a: [String] = params.extraArgs + ["-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=20"]
        if params.port != 22 && params.port > 0 { a += ["-p", String(params.port)] }
        if !params.user.isEmpty { a += ["-l", params.user] }
        if !params.keyFile.isEmpty { a += ["-i", (params.keyFile as NSString).expandingTildeInPath] }
        return a
    }

    /// マスター接続に相乗りする ssh の引数 (認証済みなので質問はしない)
    public func muxArgs() -> [String] {
        ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-x"] + (params.forwardAgent ? [] : ["-a"]) + baseArgs()
    }

    public func check() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        p.arguments = ["-S", controlPath, "-O", "check", params.host]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 相乗りの ssh プロセスを作る (まだ起動しない)。remoteArgs は ssh のホスト名の後ろ
    public func process(_ remoteArgs: [String], subsystem: Bool = false) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        p.arguments = muxArgs() + ["-T"] + (subsystem ? ["-s"] : []) + [params.host] + remoteArgs
        return p
    }

    public var isAlive: Bool { master.isRunning }

    public func cancel() { cancelled = true }

    public func close() {
        cancelled = true
        if master.isRunning {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
            p.arguments = ["-S", controlPath, "-O", "exit", params.host]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if master.isRunning { master.terminate() }
        }
        askpass?.close()
        askpass = nil
        unlink(controlPath)
    }

    deinit { close() }

    /// sh で安全に使えるように '...' で囲む
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
