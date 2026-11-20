import AppKit
import ScpCore

/// WinSCP の「コマンダー」画面: 左にローカル、右にリモートの 2 画面
final class CommanderWindowController: NSWindowController, NSWindowDelegate, FilePanelDelegate, NSToolbarDelegate, NSMenuItemValidation {
    static var all: [CommanderWindowController] = []

    let session: Session
    let local = FilePanel(remote: false)
    let remote = FilePanel(remote: true)
    private(set) var activePanel: FilePanel
    private let statusLabel = UI.label("")
    private let editors = EditManager()
    private var closing = false

    var otherPanel: FilePanel { activePanel === local ? remote : local }

    init(session: Session) {
        self.session = session
        activePanel = remote
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 700, height: 400)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "WinSCPMacSession"
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("CommanderWindow")
        buildUI()
        CommanderWindowController.all.append(self)
        remote.session = session
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let w = window else { return }
        let tb = NSToolbar(identifier: "CommanderToolbar")
        tb.delegate = self
        tb.displayMode = .iconAndLabel
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb
        if #available(macOS 11.0, *) { w.toolbarStyle = .expanded }

        for p in [local, remote] { p.delegate = self }
        local.setTitle("ローカル")
        remote.setTitle("リモート: \(session.site.displayAddress)")
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(local)
        split.addArrangedSubview(remote)
        split.autosaveName = "CommanderSplit"

        // ファンクションキーの並び (WinSCP のコマンダーの下の段と同じ)
        let keys: [(String, Selector)] = [
            ("F2 名前変更", #selector(renameFile(_:))), ("F4 編集", #selector(editFile(_:))),
            ("F5 コピー", #selector(copyFiles(_:))), ("F6 移動", #selector(moveFiles(_:))),
            ("F7 フォルダ作成", #selector(makeFolder(_:))), ("F8 削除", #selector(deleteFiles(_:))),
            ("F9 プロパティ", #selector(showProperties(_:))), ("F10 終了", #selector(closeSession(_:))),
        ]
        let fbuttons = keys.map { (t, s) -> NSButton in
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.refusesFirstResponder = true
            return b
        }
        let fbar = NSStackView(views: fbuttons)
        fbar.distribution = .fillEqually
        fbar.spacing = 2
        fbar.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let statusBar = NSStackView(views: [statusLabel])
        statusBar.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 4, right: 8)

        let v = NSStackView(views: [split, fbar, statusBar])
        v.orientation = .vertical
        v.spacing = 0
        for x in [split, fbar, statusBar] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        w.contentView = v
        DispatchQueue.main.async { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
    }

    func updateTitle() {
        let p = activePanel === remote ? RemotePath.name(remote.path) : (local.path as NSString).lastPathComponent
        window?.title = "\(p.isEmpty ? "/" : p) - \(session.title) - WinSCP Mac"
        window?.tab.title = session.title
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    /// 接続ができてから最初の表示
    func start() {
        let site = session.site
        let localStart = site.localDirectory.isEmpty ? (UserDefaults.standard.string(forKey: "LastLocalDirectory") ?? NSHomeDirectory()) : site.localDirectory
        local.navigate(FileManager.default.fileExists(atPath: (localStart as NSString).expandingTildeInPath) ? localStart : NSHomeDirectory())
        let remoteStart = site.remoteDirectory.isEmpty ? session.home : site.remoteDirectory
        remote.navigate(remoteStart) { [weak self] ok in
            guard let self = self else { return }
            if !ok && remoteStart != self.session.home { self.remote.navigate(self.session.home) }
            self.remote.focus()
        }
        setStatus("\(session.fs?.protocolName ?? site.proto.title) で \(site.displayAddress) に接続しました")
    }

    // MARK: ツールバー

    private let toolbarItems: [(String, String, String, Selector)] = [
        ("newSession", "新しいセッション", "plus.rectangle.on.rectangle", #selector(AppDelegate.newSession(_:))),
        ("refresh", "更新", "arrow.clockwise", #selector(refreshPanels(_:))),
        ("hidden", "隠しファイル", "eye", #selector(toggleHidden(_:))),
        ("compare", "比較", "arrow.left.arrow.right", #selector(compareDirectories(_:))),
        ("command", "コマンド", "chevron.left.forwardslash.chevron.right", #selector(runCommand(_:))),
        ("terminal", "ターミナル", "terminal", #selector(openTerminal(_:))),
        ("disconnect", "切断", "xmark.circle", #selector(closeSession(_:))),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.map { NSToolbarItem.Identifier($0.0) }.prefix(1) + [.space] + toolbarItems.dropFirst().map { NSToolbarItem.Identifier($0.0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.map { NSToolbarItem.Identifier($0.0) } + [.space, .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let t = toolbarItems.first(where: { $0.0 == id.rawValue }) else { return nil }
        let i = NSToolbarItem(itemIdentifier: id)
        i.label = t.1
        i.paletteLabel = t.1
        i.toolTip = t.1
        i.image = NSImage(systemSymbolName: t.2, accessibilityDescription: t.1)
        i.target = t.0 == "newSession" ? nil : self
        i.action = t.3
        return i
    }

    // MARK: パネルの代理

    func panelDidBecomeActive(_ p: FilePanel) {
        activePanel = p
        local.active = p === local
        remote.active = p === remote
        updateTitle()
    }

    func panel(_ p: FilePanel, open entry: FileEntry) {
        if p.isRemote {
            if entry.isSymlink {
                // リンクがディレクトリかもしれない (FTP では分からない)
                let path = p.join(entry.name)
                p.navigate(path) { [weak self] ok in if !ok { self?.editRemote(entry) } }
                return
            }
            editRemote(entry)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: p.join(entry.name)))
        }
    }

    func panel(_ p: FilePanel, dropLocal urls: [URL], into dir: String, move: Bool) {
        if p.isRemote {
            upload(urls, to: dir, move: move, ask: Prefs.showCopyDialog)
        } else {
            // ローカル同士 (Finder やローカル一覧から)
            let fm = FileManager.default
            for u in urls where (u.deletingLastPathComponent().path != dir) {
                let dst = (dir as NSString).appendingPathComponent(u.lastPathComponent)
                do {
                    if move { try fm.moveItem(atPath: u.path, toPath: dst) } else { try fm.copyItem(atPath: u.path, toPath: dst) }
                } catch { Dialogs.error(error) }
            }
            local.reload(select: urls.map { $0.lastPathComponent })
        }
    }

    func panel(_ p: FilePanel, dropRemote item: RemoteDrag, into dir: String, move: Bool) {
        if p.isRemote {
            // リモート内でフォルダへ移動
            guard item.dir != dir else { return }
            let names = item.entries.map(\.name)
            session.run({ fs in for n in names { try fs.rename(RemotePath.join(item.dir, n), to: RemotePath.join(dir, n)) } }) { [weak self] r in
                if case .failure(let e) = r { Dialogs.error(e) }
                self?.remote.reload()
            }
            return
        }
        download(item.entries, from: item.dir, to: dir, move: move, ask: Prefs.showCopyDialog)
    }

    func panel(_ p: FilePanel, writePromise entry: FileEntry, from dir: String, to url: URL) throws {
        // Finder へのドラッグ。キューに並んで同期で落とす
        let job = TransferJob(session: session, download: [entry], from: dir, to: url.deletingLastPathComponent().path, move: false)
        var err: Error?
        DispatchQueue.main.sync { job.sheet.show(on: self.window) }
        session.queue.sync { do { _ = try job.runSync() } catch { err = error } }
        DispatchQueue.main.sync { job.sheet.close() }
        if let e = err { throw e }
    }

    func panelContextMenu(_ p: FilePanel) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ s: Selector, _ key: String = "") {
            let i = m.addItem(withTitle: t, action: s, keyEquivalent: "")
            i.target = self
            if !key.isEmpty { i.title = t + "\t" + key }
        }
        add(p.isRemote ? "開く / 編集" : "開く", #selector(openSelected(_:)))
        add("編集", #selector(editFile(_:)), "F4")
        m.addItem(.separator())
        add(p.isRemote ? "ダウンロード…" : "アップロード…", #selector(copyFiles(_:)), "F5")
        add(p.isRemote ? "ダウンロードして削除…" : "アップロードして削除…", #selector(moveFiles(_:)), "F6")
        m.addItem(.separator())
        add("名前の変更", #selector(renameFile(_:)), "F2")
        add("削除", #selector(deleteFiles(_:)), "F8")
        add("フォルダの作成…", #selector(makeFolder(_:)), "F7")
        m.addItem(.separator())
        if p.isRemote {
            add("パスをコピー", #selector(copyPath(_:)))
        } else {
            add("Finder で表示", #selector(revealInFinder(_:)))
            add("パスをコピー", #selector(copyPath(_:)))
        }
        add("プロパティ", #selector(showProperties(_:)), "F9")
        return m
    }

    // MARK: 操作

    @objc func switchPanel(_ sender: Any?) { otherPanel.focus() }

    @objc func refreshPanels(_ sender: Any?) { activePanel.reload() }

    @objc func toggleHidden(_ sender: Any?) {
        Prefs.showHidden.toggle()
        for c in CommanderWindowController.all { c.local.applyFilterAndSort(); c.remote.applyFilterAndSort() }
        setStatus(Prefs.showHidden ? "隠しファイルを表示しています" : "隠しファイルを隠しています")
    }

    @objc func openSelected(_ sender: Any?) { activePanel.openFocused() }

    @objc func selectAllFiles(_ sender: Any?) { activePanel.selectAll() }

    /// 選択された項目 (無ければカーソルの項目)
    private func targets(_ p: FilePanel) -> [FileEntry] {
        let s = p.selectedEntries
        if !s.isEmpty { return s }
        if let f = p.focusedEntry, f.name != ".." { return [f] }
        return []
    }

    @objc func copyFiles(_ sender: Any?) { transferSelected(move: false) }
    @objc func moveFiles(_ sender: Any?) { transferSelected(move: true) }

    private func transferSelected(move: Bool) {
        let p = activePanel
        let items = targets(p)
        guard !items.isEmpty else { return }
        if p.isRemote {
            download(items, from: p.path, to: local.path, move: move, ask: true)
        } else {
            upload(items.map { URL(fileURLWithPath: p.join($0.name)) }, to: remote.path, move: move, ask: true)
        }
    }

    func upload(_ urls: [URL], to dir: String, move: Bool, ask: Bool) {
        guard !urls.isEmpty else { return }
        var target = dir
        if ask {
            guard let t = CopyDialog.run(upload: true, move: move, count: urls.count, firstName: urls[0].lastPathComponent, target: dir, parent: window) else { return }
            target = t
        }
        let job = TransferJob(session: session, upload: urls, to: target, move: move)
        job.start(parent: window) { [weak self] names, err in
            guard let self = self else { return }
            if let e = err { Dialogs.error(e) }
            self.remote.reload(select: target == self.remote.path ? names : nil)
            if move { self.local.reload() }
            if err == nil { self.setStatus("\(names.count) 個の項目を\(move ? "移動" : "アップロード")しました") }
        }
    }

    func download(_ entries: [FileEntry], from dir: String, to localDir: String, move: Bool, ask: Bool) {
        guard !entries.isEmpty else { return }
        var target = localDir
        if ask {
            guard let t = CopyDialog.run(upload: false, move: move, count: entries.count, firstName: entries[0].name, target: localDir, parent: window) else { return }
            target = (t as NSString).expandingTildeInPath
        }
        let job = TransferJob(session: session, download: entries, from: dir, to: target, move: move)
        job.start(parent: window) { [weak self] names, err in
            guard let self = self else { return }
            if let e = err { Dialogs.error(e) }
            self.local.reload(select: target == self.local.path ? names : nil)
            if move { self.remote.reload() }
            if err == nil { self.setStatus("\(names.count) 個の項目を\(move ? "移動" : "ダウンロード")しました") }
        }
    }

    @objc func renameFile(_ sender: Any?) {
        let p = activePanel
        guard let e = p.focusedEntry, e.name != ".." else { return }
        guard let n = Dialogs.input(prompt: "新しい名前:", value: e.name, title: "名前の変更", parent: window),
              !n.isEmpty, n != e.name else { return }
        if p.isRemote {
            session.run({ try $0.rename(p.join(e.name), to: p.join(n)) }) { r in
                if case .failure(let err) = r { Dialogs.error(err) }
                p.reload(select: [n])
            }
        } else {
            do { try FileManager.default.moveItem(atPath: p.join(e.name), toPath: p.join(n)) } catch { Dialogs.error(error) }
            p.reload(select: [n])
        }
    }

    @objc func makeFolder(_ sender: Any?) {
        let p = activePanel
        guard let n = Dialogs.input(prompt: "新しいフォルダの名前:", value: "新しいフォルダ", title: "フォルダの作成", parent: window),
              !n.isEmpty else { return }
        if p.isRemote {
            session.run({ try $0.makeDirectory(p.join(n)) }) { r in
                if case .failure(let err) = r { Dialogs.error(err) }
                p.reload(select: [n])
            }
        } else {
            do { try FileManager.default.createDirectory(atPath: p.join(n), withIntermediateDirectories: false) } catch { Dialogs.error(error) }
            p.reload(select: [n])
        }
    }

    @objc func deleteFiles(_ sender: Any?) {
        let p = activePanel
        let items = targets(p)
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "'\(items[0].name)'" : "\(items.count) 個の項目"
        if p.isRemote {
            if Prefs.confirmDelete && !Dialogs.confirm("\(what) を削除しますか?", "リモートのファイルは元に戻せません。", ok: "削除") { return }
            RemoteDelete.run(session: session, dir: p.path, entries: items, parent: window) { err in
                if let e = err { Dialogs.error(e) }
                p.reload()
            }
        } else {
            if Prefs.confirmDelete && !Dialogs.confirm("\(what) をゴミ箱に入れますか?", ok: "ゴミ箱に入れる") { return }
            NSWorkspace.shared.recycle(items.map { URL(fileURLWithPath: p.join($0.name)) }) { _, err in
                if let e = err { Dialogs.error(e) }
                p.reload()
            }
        }
    }

    @objc func editFile(_ sender: Any?) {
        let p = activePanel
        guard let e = p.focusedEntry, e.name != "..", !e.isDirectory else { return }
        if p.isRemote { editRemote(e) } else { EditManager.openInEditor(URL(fileURLWithPath: p.join(e.name))) }
    }

    private func editRemote(_ e: FileEntry) {
        editors.edit(session: session, dir: remote.path, entry: e, parent: window) { [weak self] msg in
            self?.setStatus(msg)
            self?.remote.reload()
        }
    }

    @objc func showProperties(_ sender: Any?) {
        let p = activePanel
        let items = targets(p)
        guard !items.isEmpty else { return }
        PropertiesDialog.run(entries: items, dir: p.path, remote: p.isRemote, parent: window) { [weak self] mode, recursive in
            guard let self = self else { return }
            let paths = items.map { p.join($0.name) }
            if p.isRemote {
                self.session.run({ fs in
                    func apply(_ path: String, _ isDir: Bool) throws {
                        try fs.setPermissions(path, mode)
                        if recursive && isDir {
                            for c in try fs.list(path) where !c.isSymlink { try apply(RemotePath.join(path, c.name), c.isDirectory) }
                        }
                    }
                    for (i, path) in paths.enumerated() { try apply(path, items[i].isDirectory) }
                }) { r in
                    if case .failure(let e) = r { Dialogs.error(e) }
                    p.reload()
                }
            } else {
                for path in paths {
                    do { try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path) }
                    catch { Dialogs.error(error); break }
                }
                p.reload()
            }
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let p = activePanel
        let paths = targets(p).map { p.join($0.name) }
        let s = paths.isEmpty ? p.path : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        setStatus("パスをコピーしました")
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = targets(local).map { URL(fileURLWithPath: local.join($0.name)) }
        if urls.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: local.path)) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// ディレクトリの比較: 相手側に無いもの・新しいものを選ぶ (WinSCP の「ディレクトリの比較」)
    @objc func compareDirectories(_ sender: Any?) {
        func pick(_ a: FilePanel, _ b: FilePanel) -> [String] {
            var other: [String: FileEntry] = [:]
            for e in b.entries where e.name != ".." { other[e.name] = e }
            return a.entries.filter { e in
                guard e.name != ".." else { return false }
                guard let o = other[e.name] else { return true }
                if e.isDirectory || o.isDirectory { return false }
                // 秒より細かい違いや FTP の分単位の時刻を考えて 1 分の余裕
                return (e.mtime ?? .distantPast).timeIntervalSince(o.mtime ?? .distantPast) > 60
            }.map(\.name)
        }
        let l = pick(local, remote), r = pick(remote, local)
        local.select(names: l)
        remote.select(names: r)
        setStatus(l.isEmpty && r.isEmpty ? "違いはありません" : "ローカルで新しい/だけにある: \(l.count) 個、リモートで新しい/だけにある: \(r.count) 個")
    }

    @objc func runCommand(_ sender: Any?) {
        CommandWindow.show(session: session, directory: remote.path) { [weak self] in self?.remote.reload() }
    }

    @objc func openTerminal(_ sender: Any?) {
        TerminalLauncher.open(site: session.site, directory: remote.path)
    }

    @objc func goToRemote(_ sender: Any?) {
        guard let p = Dialogs.input(prompt: "開くディレクトリ:", value: activePanel.path, title: "ディレクトリを開く", parent: window) else { return }
        activePanel.navigate(p)
    }

    @objc func closeSession(_ sender: Any?) { window?.performClose(sender) }

    // MARK: ウインドウ

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        if editors.hasPending, !Dialogs.confirm("編集中のファイルがあります", "セッションを閉じると、これ以降の変更はアップロードされません。閉じますか?", ok: "閉じる") {
            return false
        }
        if Prefs.confirmDisconnect && session.fs != nil && !NSApp.isTerminatingFlag {
            let a = NSAlert()
            a.messageText = "セッション '\(session.title)' を終了しますか?"
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "キャンセル")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "今後この確認を表示しない"
            let r = a.runModal()
            if a.suppressionButton?.state == .on { Prefs.confirmDisconnect = false }
            if r != .alertFirstButtonReturn { return false }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        UserDefaults.standard.set(local.path, forKey: "LastLocalDirectory")
        editors.stopAll()
        session.close()
        CommanderWindowController.all.removeAll { $0 === self }
        if CommanderWindowController.all.isEmpty && !NSApp.isTerminatingFlag {
            DispatchQueue.main.async { LoginWindowController.shared.showWindow(nil) }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateTitle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHidden(_:)):
            item.state = Prefs.showHidden ? .on : .off
            return true
        case #selector(runCommand(_:)), #selector(openTerminal(_:)):
            return session.fs != nil && (item.action != #selector(openTerminal(_:)) || session.site.proto != .ftp)
        case #selector(revealInFinder(_:)):
            return activePanel === local
        default:
            return true
        }
    }
}

extension NSApplication {
    /// 終了処理中か (終了時は確認を出さない)
    var isTerminatingFlag: Bool { (delegate as? AppDelegate)?.terminating ?? false }
}

/// コピー / 移動の確認 (転送先の指定)
enum CopyDialog {
    static func run(upload: Bool, move: Bool, count: Int, firstName: String, target: String, parent: NSWindow?) -> String? {
        let a = NSAlert()
        let verb = move ? "移動" : "コピー"
        a.messageText = upload ? "アップロード (\(verb))" : "ダウンロード (\(verb))"
        a.informativeText = (count == 1 ? "'\(firstName)'" : "\(count) 個の項目") + " を\(upload ? "リモート" : "ローカル")のディレクトリへ\(verb)します:"
        a.icon = NSImage(systemSymbolName: upload ? "arrow.up.doc" : "arrow.down.doc", accessibilityDescription: nil)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        f.stringValue = target
        let keepTime = UI.checkbox("更新日時を保持する", Prefs.preserveTime)
        let noAsk = UI.checkbox("ドラッグ＆ドロップのときはこのダイアログを表示しない", !Prefs.showCopyDialog)
        let v = NSStackView(views: [f, keepTime, noAsk])
        v.orientation = .vertical
        v.alignment = .leading
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        a.accessoryView = v
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        Prefs.preserveTime = keepTime.state == .on
        Prefs.showCopyDialog = noAsk.state == .off
        let t = f.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? target : t
    }
}

/// ターミナルで SSH を開く (WinSCP の「PuTTY で開く」)
enum TerminalLauncher {
    static func open(site: Site, directory: String) {
        var host = site.host
        if site.port != 22 && site.port > 0 { host += ":\(site.port)" }
        let target = site.user.isEmpty ? host : "\(site.user)@\(host)"
        // Tera Term Mac があればそちらで
        if Prefs.terminalApp.isEmpty || Prefs.terminalApp.contains("Tera Term"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.satoru.teramac") {
            var args = [target, "/ssh"]
            if !site.keyFile.isEmpty { args.append("/keyfile=\((site.keyFile as NSString).expandingTildeInPath)") }
            let conf = NSWorkspace.OpenConfiguration()
            conf.arguments = args
            conf.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: conf) { _, err in
                if let e = err { DispatchQueue.main.async { Dialogs.error(e) } }
            }
            return
        }
        // ターミナル.app で ssh を実行する .command ファイルを作って開く
        var cmd = "/usr/bin/ssh"
        if site.port != 22 && site.port > 0 { cmd += " -p \(site.port)" }
        if !site.keyFile.isEmpty { cmd += " -i \(SSHSession.quote((site.keyFile as NSString).expandingTildeInPath))" }
        if !site.user.isEmpty { cmd += " -l \(SSHSession.quote(site.user))" }
        cmd += " -t \(SSHSession.quote(site.host)) \(SSHSession.quote("cd \(SSHSession.quote(directory)) 2>/dev/null; exec $SHELL -l"))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WinSCPMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(site.host).command")
        let script = "#!/bin/sh\nrm -f \"$0\"\nexec \(cmd)\n"
        do {
            try script.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
            let term = Prefs.terminalApp.isEmpty ? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app") : URL(fileURLWithPath: Prefs.terminalApp)
            NSWorkspace.shared.open([f], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let e = err { DispatchQueue.main.async { Dialogs.error(e) } }
            }
        } catch { Dialogs.error(error) }
    }
}
