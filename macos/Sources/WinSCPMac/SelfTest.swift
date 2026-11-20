import AppKit
import ScpCore

/// WINSCPMAC_SNAPSHOT=<dir> で起動すると、画面を PNG に書き出し、実際に転送を試して結果を書いて終わる。
///   WINSCPMAC_LOCAL_SFTP=1 … この Mac の sftp-server と直接つなぐ (ssh を通さない)
///   WINSCPMAC_TEST_SITE=sftp://user:pass@host[:port]/path … 本物の ssh / ftp で接続する
enum SelfTest {
    static var log: [String] = []
    static var dir = ""

    static func snap(_ w: NSWindow?, _ name: String) {
        guard let v = w?.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        log.append("snap \(name)")
    }

    static func finish() {
        try? log.joined(separator: "\n").write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
        exit(0)
    }

    static func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

    static func run(dir d: String) {
        dir = d
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Prefs.showCopyDialog = Prefs.showCopyDialog  // 触るだけ
        let env = ProcessInfo.processInfo.environment
        let login = LoginWindowController.shared
        login.showWindow(nil)
        after(0.5) {
            snap(login.window, "login")
            var site = Site()
            if let t = env["WINSCPMAC_TEST_SITE"], let u = URLComponents(string: t) {
                site.proto = u.scheme == "ftp" ? .ftp : (u.scheme == "ftps" ? .ftp : (u.scheme == "scp" ? .scp : .sftp))
                if u.scheme == "ftps" { site.ftpSecurity = .explicitTLS }
                site.host = u.host ?? ""
                site.port = u.port ?? site.proto.defaultPort
                site.user = u.user ?? ""
                site.password = u.password ?? ""
                site.remoteDirectory = u.path
            } else {
                site.host = "localhost-sftp-server"
                site.user = NSUserName()
            }
            // テスト用のローカルフォルダ
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("winscpmac-selftest-\(getpid())")
            let localDir = work.appendingPathComponent("local"), remoteDir = work.appendingPathComponent("remote")
            for x in [localDir, remoteDir] { try? FileManager.default.createDirectory(at: x, withIntermediateDirectories: true) }
            try? "こんにちは WinSCP Mac\n".write(to: localDir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
            try? Data(repeating: 0x41, count: 2_000_000).write(to: localDir.appendingPathComponent("big.bin"))
            try? FileManager.default.createDirectory(at: localDir.appendingPathComponent("フォルダ/sub"), withIntermediateDirectories: true)
            try? "nested".write(to: localDir.appendingPathComponent("フォルダ/sub/n.txt"), atomically: true, encoding: .utf8)
            try? "remote file".write(to: remoteDir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
            try? FileManager.default.createDirectory(at: remoteDir.appendingPathComponent("www"), withIntermediateDirectories: true)
            site.localDirectory = localDir.path
            if site.host == "localhost-sftp-server" { site.remoteDirectory = remoteDir.path }

            let s = Session(site: site)
            let t0 = Date()
            s.connect(parent: { nil }) { err in
                if let e = err { log.append("connect FAILED: \(e.localizedDescription)"); finish(); return }
                log.append("connected \(s.fs?.protocolName ?? "?") home=\(s.home) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                let c = CommanderWindowController(session: s)
                c.showWindow(nil)
                c.window?.setContentSize(NSSize(width: 1100, height: 620))
                c.start()
                after(2.0) {
                    log.append("remote: \(c.remote.path) entries=\(c.remote.entries.map(\.name))")
                    log.append("local: \(c.local.path) entries=\(c.local.entries.map(\.name))")
                    snap(c.window, "commander")
                    if env["WINSCPMAC_TEST_SITE"] != nil && site.host != "localhost-sftp-server" && env["WINSCPMAC_TEST_WRITE"] != "1" {
                        // 読み取り専用のテストサーバー: ダウンロードだけ試す
                        let files = c.remote.entries.filter { !$0.isDirectory && $0.size < 5_000_000 }.prefix(2)
                        c.download(Array(files), from: c.remote.path, to: c.local.path, move: false, ask: false)
                        after(6.0) {
                            for f in files {
                                let a = try? FileManager.default.attributesOfItem(atPath: c.local.join(f.name))
                                log.append("download \(f.name): \((a?[.size] as? NSNumber)?.uint64Value ?? 0) / \(f.size)")
                            }
                            snap(c.window, "commander-after")
                            finish()
                        }
                        return
                    }
                    // アップロード (フォルダごと) → 名前変更 → ダウンロード → 削除
                    let ups = ["hello.txt", "big.bin", "フォルダ"].map { localDir.appendingPathComponent($0) }
                    c.upload(ups, to: c.remote.path, move: false, ask: false)
                    after(3.0) {
                        log.append("after upload remote=\(c.remote.entries.map(\.name))")
                        s.run({ fs -> [String] in
                            try fs.rename(RemotePath.join(c.remote.path, "hello.txt"), to: RemotePath.join(c.remote.path, "hello2.txt"))
                            try fs.setPermissions(RemotePath.join(c.remote.path, "hello2.txt"), 0o600)
                            return try fs.list(RemotePath.join(c.remote.path, "フォルダ/sub")).map(\.name)
                        }) { r in
                            log.append("nested list: \(r)")
                            c.remote.reload {
                                snap(c.window, "commander-after")
                                let dl = c.remote.entries.filter { $0.name == "hello2.txt" || $0.name == "www" }
                                c.download(dl, from: c.remote.path, to: c.local.path, move: false, ask: false)
                                after(2.0) {
                                    let txt = (try? String(contentsOf: localDir.appendingPathComponent("hello2.txt"))) ?? "(なし)"
                                    log.append("downloaded hello2.txt: \(txt.trimmingCharacters(in: .newlines))")
                                    log.append("local now: \(c.local.entries.map(\.name))")
                                    let e = c.remote.entries.first { $0.name == "hello2.txt" }
                                    log.append("rights hello2: \(e?.rightsString ?? "-")")
                                    RemoteDelete.run(session: s, dir: c.remote.path, entries: c.remote.entries.filter { $0.name == "フォルダ" }, parent: c.window) { err in
                                        log.append("delete folder: \(err?.localizedDescription ?? "ok")")
                                        c.remote.reload {
                                            log.append("final remote=\(c.remote.entries.map(\.name))")
                                            if site.host == "localhost-sftp-server" { try? FileManager.default.removeItem(at: work) }
                                            finish()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
