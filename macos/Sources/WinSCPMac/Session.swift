import AppKit
import ScpCore

/// 1 つの接続。リモートの操作はすべて専用のキューで順番に行う
final class Session {
    let site: Site
    private(set) var fs: RemoteFileSystem?
    let queue = DispatchQueue(label: "session")
    private var sshSession: SSHSession?
    var home = "/"
    /// 接続の保持 (FTP の NOOP) のタイマーと、最後にリモートを使った時刻
    private var keepAliveTimer: DispatchSourceTimer?
    private var lastUse = Date()

    init(site: Site) { self.site = site }

    var title: String { site.name.isEmpty ? site.displayAddress : site.shortName }

    /// ssh のテスト用: 環境変数でテスト用の追加オプションを渡せる (既知ホストファイルの場所など)
    static var testSSHArgs: [String] {
        guard let s = ProcessInfo.processInfo.environment["WINSCPMAC_SSH_ARGS"], !s.isEmpty else { return [] }
        return s.split(separator: " ").map(String.init)
    }

    /// 接続する (バックグラウンドで)。質問は parent のウインドウにダイアログで出す
    func connect(parent: @escaping () -> NSWindow?, completion: @escaping (Error?) -> Void) {
        let site = self.site
        var usedSavedPassword = false
        var usedTunnelPassword = false
        // WinSCP の「高度なサイトの設定」 (WinSCP.ini のキー名のまま)
        let opts = WinSCPSessionData(site.settings)
        queue.async {
            do {
                let fs: RemoteFileSystem
                if ProcessInfo.processInfo.environment["WINSCPMAC_LOCAL_SFTP"] == "1" && site.host == "localhost-sftp-server" {
                    // 自己テスト: ssh を通さず、この Mac の sftp-server と直接話す
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
                    fs = try SFTPClient.start(process: p)
                } else if site.proto == .ftp {
                    var pw = site.password
                    if pw.isEmpty && !site.user.isEmpty && site.user != "anonymous" {
                        guard let p = Session.askOnMain({ Dialogs.password(prompt: "\(site.displayAddress) のパスワード:", parent: parent()) }) else {
                            throw RemoteError.cancelled
                        }
                        pw = p
                    }
                    let port = site.port > 0 ? site.port : (site.ftpSecurity == .implicitTLS ? 990 : 21)
                    let fp = SessionOptions.ftp(opts, .init(host: site.host, port: port, user: site.user, password: pw,
                                                            security: site.ftpSecurity, passive: site.passive))
                    fs = try FTPClient(fp, certificateHandler: { summary, fp in
                        Session.askOnMain { Dialogs.confirmCertificate(summary: summary, fingerprint: fp, parent: parent()) } ?? false
                    })
                } else {
                    var params = SSHParams(host: site.host, port: site.port, user: site.user, keyFile: site.keyFile,
                                           extraArgs: Session.testSSHArgs)
                    params.apply(SessionOptions.ssh(opts, host: site.host, port: site.port, tunnelExtraArgs: Session.testSSHArgs))
                    let tunnel = opts.bool("Tunnel", false) ? opts.string("TunnelHostName") : ""
                    let tunnelPassword = opts.tunnelPassword
                    // 「パスワードを自動送信する」(AuthKIPassword) が off なら、キーボード認証の質問には保存したパスワードを使わない
                    let kiPassword = opts.bool("AuthKIPassword", true)
                    fs = try SSHConnector.connect(params, protocol: site.proto,
                                                  askpassProgram: Bundle.main.executablePath ?? CommandLine.arguments[0],
                                                  handler: { prompt, kind in
                        switch kind {
                        case .password:
                            // トンネル (踏み台) のパスワード: "user@踏み台's password:"
                            if !tunnel.isEmpty && prompt.contains("@\(tunnel)") {
                                if !usedTunnelPassword && !tunnelPassword.isEmpty {
                                    usedTunnelPassword = true
                                    return tunnelPassword
                                }
                                return Session.askOnMain { Dialogs.password(prompt: prompt, parent: parent()) }
                            }
                            let isKI = !prompt.contains("'s password")
                            if !usedSavedPassword && !site.password.isEmpty && prompt.lowercased().contains("password") && (kiPassword || !isKI) {
                                usedSavedPassword = true
                                return site.password
                            }
                            return Session.askOnMain { Dialogs.password(prompt: prompt, parent: parent()) }
                        case .hostKey:
                            let ok = Session.askOnMain { Dialogs.confirmHostKey(prompt, parent: parent()) } ?? false
                            return ok ? "yes" : "no"
                        case .other:
                            return Session.askOnMain { Dialogs.input(prompt: prompt, parent: parent()) }
                        }
                    }, sessionCreated: { [weak self] s in self?.sshSession = s })
                }
                // SCP の設定 (一覧のコマンド・タイムゾーン補正)
                if let scp = fs as? SCPClient {
                    scp.listingCommand = opts.string("ListingCommand", "ls -la")
                    scp.lsFullTime = opts.autoSwitch("SCPLsFullTime") != .off
                    scp.timeDifference = TimeInterval(opts.timeDifferenceMinutes * 60)
                }
                let h = (try? fs.homeDirectory()) ?? "/"
                self.fs = fs
                self.home = h
                self.lastUse = Date()
                // FTP の接続の保持 (FtpPingType: 0 オフ, 1/2 ダミー コマンド, 3 ディレクトリの読み込みも)
                if fs is FTPClient {
                    let type = opts.int("FtpPingType", 2)
                    let interval = max(1, opts.int("FtpPingInterval", 30))
                    if type != 0 { self.startKeepAlive(interval: interval, listing: type == 3) }
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    static func askOnMain<T>(_ f: @escaping () -> T?) -> T? {
        if Thread.isMainThread { return f() }
        var r: T?
        DispatchQueue.main.sync { r = f() }
        return r
    }

    /// 接続の途中で止める
    func cancelConnect() { sshSession?.cancel() }

    /// しばらく使っていなければ、FTP のダミー コマンドを送って接続を保つ
    private func startKeepAlive(interval: Int, listing: Bool) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            guard let self = self, let ftp = self.fs as? FTPClient else { return }
            guard Date().timeIntervalSince(self.lastUse) >= Double(interval) - 0.5 else { return }
            try? ftp.keepAlive()
            if listing { _ = try? ftp.list(self.home) }
            self.lastUse = Date()
        }
        keepAliveTimer = t
        t.resume()
    }

    /// リモートの操作をキューで行い、結果をメインスレッドで受け取る
    func run<T>(_ work: @escaping (RemoteFileSystem) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let r: Result<T, Error>
            if let fs = self.fs {
                self.lastUse = Date()
                r = Result { try work(fs) }
            } else {
                r = .failure(RemoteError("接続されていません"))
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// 同期で操作する (キューの上で動いているときに使う)
    func sync<T>(_ work: (RemoteFileSystem) throws -> T) throws -> T {
        guard let fs = fs else { throw RemoteError("接続されていません") }
        lastUse = Date()
        defer { lastUse = Date() }
        return try work(fs)
    }

    func close() {
        let fs = self.fs
        self.fs = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        sshSession?.cancel()
        DispatchQueue.global().async { fs?.close() }
    }

    var canRunCommands: Bool { fs is SFTPOverSSH || fs is SCPClient || fs is FTPClient }
}
