import AppKit
import Security

/// 更新の確認と簡単更新 (WinSCP の「WinSCP の更新を確認」と自動更新に相当)。
/// 新しい版は GitHub の Releases (satorunet/winscp_mac) に DMG を付けて公開する。
/// 設定は WinSCP と同じキー (Configuration\Interface\Updates\...):
///   Period: 確認の間隔 (日。0 = 自動更新しない) / ShowOnStartup: 起動時に更新情報を表示する
///   BetaVersions: ベータ版 (プレリリース) も確認する / ConnectionType, ProxyHost, ProxyPort: 接続
///   LastCheck: 前回の確認 (WinSCP の日時の形式)
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    static let repo = "satorunet/winscp_mac"
    static let U = "Configuration\\Interface\\Updates\\"

    struct Release {
        let version: String
        let tag: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
        let dmgSize: Int64
    }

    // MARK: 設定

    /// 確認の間隔 (日)。WinSCP 本体の既定は 0 だが、インストーラーが毎週 (7) にするので、ここでも毎週を既定にする
    static var period: Int { WinSCPConfig.shared.int(U + "Period", 7) }
    static var showOnStartup: Bool { WinSCPConfig.shared.bool(U + "ShowOnStartup", true) }
    /// TAutoSwitch: 0 = オン, 1 = オフ, 2 = 自動 (WinSCP の既定は自動 = 使っているのが正式版ならオフ)
    static var includeBeta: Bool { WinSCPConfig.shared.int(U + "BetaVersions", 2) == 0 }

    static var lastCheck: Date? {
        get {
            let v = WinSCPConfig.shared.string(U + "LastCheck")
            // WinSCP の日時 (TDateTime: 1899/12/30 からの日数を double の 16 進で)
            guard !v.isEmpty, let days = WinSCPConfig.decodeDouble(v) else { return nil }
            return Date(timeIntervalSince1970: (days - 25569) * 86400)
        }
        set { WinSCPConfig.shared.set(U + "LastCheck", newValue.map { WinSCPConfig.encodeDouble($0.timeIntervalSince1970 / 86400 + 25569) }) }
    }

    static var currentVersion: String {
        ProcessInfo.processInfo.environment["WINSCPMAC_FAKE_VERSION"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }

    /// 起動時に確認する時期か
    static var isDue: Bool {
        guard period > 0 else { return false }
        if ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_FORCE"] == "1" { return true }
        guard let last = lastCheck else { return true }
        return Date().timeIntervalSince(last) >= Double(period) * 86400
    }

    /// "1.2.10" > "1.2.9"
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: 確認

    private func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        // 接続: 0 = プロキシを使用しない, 1 = 自動検出 (macOS の設定), 2 = プロキシ サーバを使用する
        switch WinSCPConfig.shared.int(Updater.U + "ConnectionType", 1) {
        case 0: c.connectionProxyDictionary = [:]
        case 2:
            let host = WinSCPConfig.shared.string(Updater.U + "ProxyHost")
            let port = WinSCPConfig.shared.int(Updater.U + "ProxyPort", 8080)
            if !host.isEmpty {
                c.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: host, kCFNetworkProxiesHTTPPort as String: port,
                    kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: host, kCFNetworkProxiesHTTPSPort as String: port,
                ]
            }
        default: break
        }
        return URLSession(configuration: c)
    }

    /// GitHub の Releases から最新版を調べる
    func fetchLatest(timeout: TimeInterval = 15, completion: @escaping (Result<Release?, Error>) -> Void) {
        let beta = Updater.includeBeta
        let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=20")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WinSCPMac/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        session(timeout: timeout).dataTask(with: req) { data, resp, err in
            let r: Result<Release?, Error>
            if let e = err {
                r = .failure(e)
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                r = .failure(NSError(domain: "Updater", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            } else if let d = data, let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                let releases = list.compactMap { j -> Release? in
                    guard j["draft"] as? Bool != true, beta || j["prerelease"] as? Bool != true,
                          let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                    let assets = j["assets"] as? [[String: Any]] ?? []
                    let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
                    return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), tag: tag,
                                   notes: j["body"] as? String ?? "", pageURL: page,
                                   dmgURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                   dmgSize: (dmg?["size"] as? NSNumber)?.int64Value ?? 0)
                }
                let newest = releases.max { Updater.isNewer($1.version, than: $0.version) }
                r = .success(newest.flatMap { Updater.isNewer($0.version, than: Updater.currentVersion) ? $0 : nil })
            } else {
                r = .failure(NSError(domain: "Updater", code: 0, userInfo: [NSLocalizedDescriptionKey: "応答を読めません"]))
            }
            DispatchQueue.main.async { completion(r) }
        }.resume()
    }

    /// 起動時: 時期が来ていれば確認し、新しい版があれば (起動時に表示する設定なら) 知らせる。終わったら then を呼ぶ
    func checkOnStartup(then: @escaping () -> Void) {
        guard Updater.isDue else { then(); return }
        // 起動を長く待たせない (4 秒で打ち切り、ログイン画面を出す)
        var finished = false
        let finish = { if !finished { finished = true; then() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish() }
        fetchLatest(timeout: 4) { r in
            if case .success(let rel) = r {
                Updater.lastCheck = Date()
                if let rel = rel, Updater.showOnStartup, !finished {
                    finished = true
                    self.offer(rel, onClose: then)
                    return
                }
            }
            finish()
        }
    }

    /// 「WinSCP の更新を確認」(メニューから)
    @objc func checkNow(_ sender: Any?) {
        fetchLatest { r in
            switch r {
            case .failure(let e):
                Dialogs.message(Translations.str("CHECK_FOR_UPDATES_ERROR"), e.localizedDescription)
            case .success(nil):
                Updater.lastCheck = Date()
                Dialogs.message(Translations.str("CHECK_FOR_UPDATES_TITLE"),
                                Translations.str("NO_NEW_VERSION") + "\n\n" + Translations.fmt("UPDATE_CURRENT", Updater.currentVersion))
            case .success(let rel?):
                Updater.lastCheck = Date()
                self.offer(rel, onClose: {})
            }
        }
    }

    // MARK: 知らせる

    /// 新しい版のお知らせ。「更新」で簡単更新、「移動」でリリースのページ
    func offer(_ rel: Release, onClose: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = Translations.str("CHECK_FOR_UPDATES_TITLE")
        a.informativeText = Translations.fmt("NEW_VERSION4", rel.version) + "\n" + Translations.fmt("UPDATE_CURRENT", Updater.currentVersion)
        a.icon = NSApp.applicationIconImage
        // 更新点 (リリースの説明)
        if !rel.notes.isEmpty {
            let s = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            let t = NSTextView(frame: s.bounds)
            t.string = rel.notes
            t.isEditable = false
            t.font = .systemFont(ofSize: 12)
            t.autoresizingMask = [.width]
            s.documentView = t
            a.accessoryView = s
        }
        let canInstall = rel.dmgURL != nil
        a.addButton(withTitle: Translations.clean(Translations.str("UPGRADE_BUTTON")))     // 更新
        a.addButton(withTitle: "後で")
        a.addButton(withTitle: Translations.clean(Translations.str("UPDATE_URL_BUTTON")))  // 移動
        a.buttons[0].isEnabled = canInstall
        NSApp.activate(ignoringOtherApps: true)
        let auto = ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_AUTO"] == "1"
        let r = auto ? .alertFirstButtonReturn : a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            install(rel, onFail: {
                if let log = ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_LOG"], auto {
                    try? "failed".write(toFile: log, atomically: true, encoding: .utf8)
                    exit(1)
                }
                onClose()
            })
        case .alertThirdButtonReturn: NSWorkspace.shared.open(rel.pageURL); onClose()
        default: onClose()
        }
    }

    // MARK: 簡単更新 (ダウンロード → 署名の確認 → 入れ替え → 再起動)

    private var progressWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var downloadDone: ((URL?, Error?) -> Void)?
    private var downloadSession: URLSession?

    func install(_ rel: Release, onFail: @escaping () -> Void) {
        guard let url = rel.dmgURL else { onFail(); return }
        showProgress("WinSCP Mac \(rel.version) をダウンロードしています…")
        downloadDone = { [weak self] file, err in
            guard let self = self else { return }
            guard let file = file, err == nil else {
                self.closeProgress()
                Updater.report(Translations.str("UPDATE_DOWNLOAD_ERROR"), err?.localizedDescription ?? "")
                onFail()
                return
            }
            self.progressLabel?.stringValue = "更新を確認して入れ替えています…"
            self.progressBar?.isIndeterminate = true
            self.progressBar?.startAnimation(nil)
            DispatchQueue.global().async {
                let result = Result { try Updater.replaceApp(withDMG: file) }
                DispatchQueue.main.async {
                    self.closeProgress()
                    switch result {
                    case .success(let newApp):
                        Updater.relaunch(newApp)
                    case .failure(let e):
                        Updater.report(Translations.str("UPDATE_VERIFY_ERROR"), e.localizedDescription)
                        onFail()
                    }
                }
            }
        }
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        downloadSession = s
        s.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressBar?.isIndeterminate = false
        progressBar?.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // この呼び出しの後で消されるので、別の場所へ移す
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("WinSCPMac-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                downloadDone?(nil, NSError(domain: "Updater", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            } else {
                downloadDone?(dst, nil)
            }
        } catch { downloadDone?(nil, error) }
        downloadDone = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { downloadDone?(nil, e); downloadDone = nil }
        session.finishTasksAndInvalidate()
    }

    private func showProgress(_ text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = Translations.str("CHECK_FOR_UPDATES_TITLE")
        let l = NSTextField(labelWithString: text)
        let b = NSProgressIndicator()
        b.style = .bar
        b.isIndeterminate = true
        b.minValue = 0; b.maxValue = 1
        b.startAnimation(nil)
        let v = NSStackView(views: [l, b])
        v.orientation = .vertical
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        b.widthAnchor.constraint(equalToConstant: 380).isActive = true
        w.contentView = v
        w.center()
        w.makeKeyAndOrderFront(nil)
        progressWindow = w; progressBar = b; progressLabel = l
    }

    private func closeProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    /// DMG の中のアプリを確かめて、いま動いているアプリと入れ替える。入れ替えたアプリの場所を返す
    static func replaceApp(withDMG dmg: URL) throws -> URL {
        defer { try? FileManager.default.removeItem(at: dmg) }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("WinSCPMac-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "DMG の中にアプリがありません"])
        }
        let newApp = mount.appendingPathComponent(appName)
        try verify(newApp)

        // 入れ替え: 同じフォルダに一度コピーしてから、古いものと差し替える
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(parent.path) に書き込めません。DMG から手動でアプリをコピーしてください。"])
        }
        let staged = parent.appendingPathComponent(".\(appName).update")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        try verify(staged)
        _ = try FileManager.default.replaceItemAt(current, withItemAt: staged, backupItemName: nil, options: [])
        return current
    }

    /// 署名が正しく、いま動いているアプリと同じ開発者 (Team ID)・同じバンドル ID であること
    static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let c = code else {
            throw NSError(domain: "Updater", code: 3, userInfo: [NSLocalizedDescriptionKey: "署名を読めません"])
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var err: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(c, flags, nil, &err) == errSecSuccess else {
            throw err?.takeRetainedValue() as Error? ?? NSError(domain: "Updater", code: 4, userInfo: [NSLocalizedDescriptionKey: "署名が正しくありません"])
        }
        let newInfo = signingInfo(c)
        let mine = currentSigningInfo()
        guard newInfo.bundleID == (Bundle.main.bundleIdentifier ?? newInfo.bundleID) else {
            throw NSError(domain: "Updater", code: 5, userInfo: [NSLocalizedDescriptionKey: "別のアプリです (\(newInfo.bundleID ?? "?"))"])
        }
        // いまのアプリが Developer ID で署名されていれば、同じ開発者のものだけ受け入れる
        if let team = mine.team, newInfo.team != team {
            throw NSError(domain: "Updater", code: 6, userInfo: [NSLocalizedDescriptionKey: "署名した開発者が違います (\(newInfo.team ?? "なし"))"])
        }
    }

    static func signingInfo(_ c: SecStaticCode) -> (team: String?, bundleID: String?) {
        var info: CFDictionary?
        SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let d = info as? [String: Any] ?? [:]
        return (d[kSecCodeInfoTeamIdentifier as String] as? String, d[kSecCodeInfoIdentifier as String] as? String)
    }

    static func currentSigningInfo() -> (team: String?, bundleID: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let c = code else { return (nil, nil) }
        return signingInfo(c)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\((tool as NSString).lastPathComponent): \(String(decoding: e, as: UTF8.self))"])
        }
        return String(decoding: o, as: UTF8.self)
    }

    /// エラーを知らせる (自己テストではログに書く)
    static func report(_ title: String, _ info: String) {
        if let log = ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_LOG"], ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_AUTO"] == "1" {
            try? "\(title) \(info)".write(toFile: log + ".err", atomically: true, encoding: .utf8)
            return
        }
        Dialogs.message(title, info)
    }

    /// このアプリが終わるのを待って、新しいアプリを開く
    static func relaunch(_ app: URL) {
        if ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_AUTO"] == "1" {
            // 自己テスト: 入れ替えまで。結果を WINSCPMAC_UPDATE_LOG に書いて終わる
            let v = (try? String(contentsOf: app.appendingPathComponent("Contents/Info.plist"))).flatMap { t -> String? in
                guard let r = t.range(of: "<key>CFBundleShortVersionString</key><string>") else { return nil }
                return String(t[r.upperBound...].prefix { $0 != "<" })
            } ?? "?"
            if let log = ProcessInfo.processInfo.environment["WINSCPMAC_UPDATE_LOG"] {
                try? "updated \(app.path) to \(v)".write(toFile: log, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
