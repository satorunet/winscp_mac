import AppKit
import ScpCore

/// ログイン画面 (WinSCP の「ログイン」ダイアログ = サイトマネージャー)
/// 左に保存済みサイトの木、右に接続先の入力欄
final class LoginWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = LoginWindowController()

    /// 木の項目
    final class Node {
        let name: String        // 表示名
        let path: String        // フォルダのフルパス / サイトの name
        let site: Site?
        var children: [Node] = []
        let isNew: Bool
        init(name: String, path: String, site: Site?, isNew: Bool = false) { self.name = name; self.path = path; self.site = site; self.isNew = isNew }
        var isFolder: Bool { site == nil && !isNew }
    }

    private var roots: [Node] = []
    private let newNode = Node(name: "新しいサイト", path: "", site: nil, isNew: true)
    private let outline = NSOutlineView()

    private let protoPopup = NSPopUpButton()
    private let secPopup = NSPopUpButton()
    private let secLabel = UI.label("暗号化:")
    private let hostField = UI.field()
    private let portField = UI.field("22", width: 70)
    private let userField = UI.field()
    private let passField = NSSecureTextField()
    private let keyField = UI.field()
    private let keyButton = NSButton()
    private let keyLabel = UI.label("秘密鍵:")
    private let remoteDirField = UI.field()
    private let localDirField = UI.field()
    private let saveButton = NSButton()
    private let loginButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var sessionGrid: NSGridView?
    private var connecting: Session?
    /// 選んでいるサイト (新しいサイトなら nil)
    private var current: Site?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "ログイン - WinSCP Mac"
        w.minSize = NSSize(width: 680, height: 420)
        super.init(window: w)
        w.delegate = self
        build()
        reloadTree()
        NotificationCenter.default.addObserver(self, selector: #selector(sitesChanged), name: SiteStore.changed, object: nil)
        w.setFrameAutosaveName("LoginWindow")
        if w.frame.origin == .zero { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 組み立て

    private func build() {
        guard let w = window else { return }
        // 左: サイトの木
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 20
        outline.doubleAction = #selector(outlineDoubleClicked(_:))
        outline.target = self
        outline.autosaveExpandedItems = false
        outline.menu = manageMenu()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let toolsButton = NSPopUpButton(frame: .zero, pullsDown: true)
        toolsButton.menu = toolsMenu()
        let manageButton = NSPopUpButton(frame: .zero, pullsDown: true)
        manageButton.menu = manageMenu(withTitle: true)
        let leftButtons = NSStackView(views: [toolsButton, manageButton])
        let left = NSStackView(views: [scroll, leftButtons])
        left.orientation = .vertical
        left.alignment = .leading

        // 右: 入力欄
        for p in FileProtocol.allCases { protoPopup.addItem(withTitle: p.title); protoPopup.lastItem?.tag = p.rawValue }
        protoPopup.target = self
        protoPopup.action = #selector(protocolChanged(_:))
        for s in FTPSecurity.allCases { secPopup.addItem(withTitle: s.title); secPopup.lastItem?.tag = s.rawValue }
        secPopup.target = self
        secPopup.action = #selector(securityChanged(_:))
        hostField.placeholderString = "example.com"
        userField.placeholderString = "ユーザー名"
        passField.placeholderString = "(空なら接続時に聞きます)"
        keyField.placeholderString = "~/.ssh/id_ed25519 (空なら ssh の設定どおり)"
        keyButton.title = "…"
        keyButton.bezelStyle = .rounded
        keyButton.target = self
        keyButton.action = #selector(chooseKey(_:))
        remoteDirField.placeholderString = "(ホームディレクトリ)"
        localDirField.placeholderString = "(前回のディレクトリ)"
        for f in [hostField, userField, passField, keyField, portField, remoteDirField, localDirField] { f.delegate = self }

        let protoRow = NSStackView(views: [protoPopup, secLabel, secPopup])
        let hostRow = NSStackView(views: [hostField, UI.label("ポート番号:"), portField])
        let keyRow = NSStackView(views: [keyField, keyButton])
        let session = UI.grid([
            [UI.label("転送プロトコル:"), protoRow],
            [UI.label("ホスト名:"), hostRow],
            [UI.label("ユーザー名:"), userField],
            [UI.label("パスワード:"), passField],
            [keyLabel, keyRow],
            [UI.label("リモートの場所:"), remoteDirField],
            [UI.label("ローカルの場所:"), localDirField],
        ])
        session.column(at: 1).width = 400
        sessionGrid = session
        let box = NSBox()
        box.title = "セッション"
        box.contentView = session
        box.contentViewMargins = NSSize(width: 12, height: 12)

        saveButton.title = "保存…"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveSite(_:))
        let saveRow = NSStackView(views: [NSView(), saveButton])

        loginButton.title = "ログイン"
        loginButton.bezelStyle = .rounded
        loginButton.keyEquivalent = "\r"
        loginButton.target = self
        loginButton.action = #selector(login(_:))
        let close = UI.button("閉じる", self, #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let bottom = NSStackView(views: [spinner, NSView(), loginButton, close])

        let right = NSStackView(views: [box, saveRow, NSView(), bottom])
        right.orientation = .vertical
        right.alignment = .leading
        for x in [box, saveRow, bottom] { x.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }

        let main = NSStackView(views: [left, right])
        main.alignment = .top
        main.spacing = 14
        main.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        left.heightAnchor.constraint(equalTo: main.heightAnchor, constant: -32).isActive = true
        right.heightAnchor.constraint(equalTo: main.heightAnchor, constant: -32).isActive = true
        w.contentView = main
        w.initialFirstResponder = hostField
        updateProtocolUI()
    }

    private func toolsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "ツール", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "WinSCP の設定 (WinSCP.ini / .reg) からサイトを読み込む…", action: #selector(importIni(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "WinSCP.ini にサイトを書き出す…", action: #selector(exportIni(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "~/.ssh/config からサイトを読み込む…", action: #selector(importSSHConfig(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "設定…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: "")
        m.addItem(withTitle: "WinSCP Mac について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        return m
    }

    private func manageMenu(withTitle: Bool = false) -> NSMenu {
        let m = NSMenu()
        if withTitle { m.addItem(withTitle: "管理", action: nil, keyEquivalent: "") }
        for (t, s) in [("新しいサイト", #selector(newSite(_:))), ("複製", #selector(duplicateSite(_:))),
                       ("名前の変更…", #selector(renameItem(_:))), ("削除", #selector(deleteItem(_:))),
                       ("新しいフォルダ…", #selector(newFolder(_:)))] {
            m.addItem(withTitle: t, action: s, keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: "ログイン", action: #selector(login(_:)), keyEquivalent: "").target = self
        return m
    }

    // MARK: 木

    @objc private func sitesChanged() { reloadTree() }

    private func reloadTree() {
        let expanded = Set((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Node }.filter { outline.isItemExpanded($0) }.map(\.path))
        let selectedPath = (outline.item(atRow: outline.selectedRow) as? Node).map { $0.site?.id.uuidString ?? $0.path }
        var folderNodes: [String: Node] = [:]
        var top: [Node] = []
        func folder(_ path: String) -> Node {
            if let n = folderNodes[path] { return n }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let n = Node(name: name, path: path, site: nil)
            folderNodes[path] = n
            if let r = path.range(of: "/", options: .backwards) { folder(String(path[..<r.lowerBound])).children.append(n) }
            else { top.append(n) }
            return n
        }
        for f in SiteStore.shared.folders { _ = folder(f) }
        for s in SiteStore.shared.sites {
            let n = Node(name: s.shortName, path: s.name, site: s)
            if s.folder.isEmpty { top.append(n) } else { folder(s.folder).children.append(n) }
        }
        func sort(_ list: inout [Node]) {
            list.sort { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for n in list { sort(&n.children) }
        }
        sort(&top)
        roots = [newNode] + top
        outline.reloadData()
        for p in expanded { if let n = folderNodes[p] { outline.expandItem(n) } }
        // 選択を戻す
        if let sp = selectedPath {
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? Node, (n.site?.id.uuidString ?? n.path) == sp {
                    outline.selectRowIndexes([r], byExtendingSelection: false)
                    return
                }
            }
        }
        if outline.selectedRow < 0 {
            if let last = UserDefaults.standard.string(forKey: "LastSite"), let id = UUID(uuidString: last), selectSite(id) { return }
            outline.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @discardableResult
    func selectSite(_ id: UUID) -> Bool {
        guard let s = SiteStore.shared.sites.first(where: { $0.id == id }) else { return false }
        // 親フォルダを開く
        var parts: [String] = []
        for p in s.folder.split(separator: "/") {
            parts.append(String(p))
            let path = parts.joined(separator: "/")
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? Node, n.isFolder, n.path == path { outline.expandItem(n) }
            }
        }
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? Node, n.site?.id == id {
                outline.selectRowIndexes([r], byExtendingSelection: false)
                outline.scrollRowToVisible(r)
                return true
            }
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isFolder ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = NSTableCellView()
        let iv = NSImageView()
        let t = NSTextField(labelWithString: n.name)
        t.lineBreakMode = .byTruncatingTail
        if n.isNew {
            iv.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        } else if n.isFolder {
            iv.image = NSImage(named: NSImage.folderName)
        } else {
            iv.image = NSImage(systemSymbolName: n.site?.proto == .ftp ? "server.rack" : "desktopcomputer", accessibilityDescription: nil)
        }
        for v in [iv, t] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = iv
        cell.textField = t
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
            t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = selectedNode else { return }
        if n.isNew {
            current = nil
            fill(Site())
        } else if let s = n.site, let full = SiteStore.shared.site(s.id) {
            current = full
            fill(full)
        }
    }

    @objc func outlineDoubleClicked(_ sender: Any?) {
        guard let n = selectedNode else { return }
        if n.isFolder {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else if n.site != nil {
            login(nil)
        }
    }

    // MARK: 入力欄

    private func fill(_ s: Site) {
        protoPopup.selectItem(withTag: s.proto.rawValue)
        secPopup.selectItem(withTag: s.ftpSecurity.rawValue)
        hostField.stringValue = s.host
        portField.stringValue = String(s.port)
        userField.stringValue = s.user
        passField.stringValue = s.password
        keyField.stringValue = s.keyFile
        remoteDirField.stringValue = s.remoteDirectory
        localDirField.stringValue = s.localDirectory
        updateProtocolUI()
    }

    /// 入力欄の内容 (選んでいるサイトに上書き)
    private func formSite() -> Site {
        var s = current ?? Site()
        s.proto = FileProtocol(rawValue: protoPopup.selectedTag()) ?? .sftp
        s.ftpSecurity = s.proto == .ftp ? (FTPSecurity(rawValue: secPopup.selectedTag()) ?? .none) : .none
        var host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        // "user@host" と書かれたら分ける
        if user.isEmpty, let at = host.lastIndex(of: "@") {
            user = String(host[..<at]); host = String(host[host.index(after: at)...])
        }
        s.host = host
        s.user = user
        s.port = Int(portField.stringValue) ?? s.proto.defaultPort
        s.password = passField.stringValue
        s.keyFile = s.proto == .ftp ? "" : keyField.stringValue.trimmingCharacters(in: .whitespaces)
        s.remoteDirectory = remoteDirField.stringValue.trimmingCharacters(in: .whitespaces)
        s.localDirectory = localDirField.stringValue.trimmingCharacters(in: .whitespaces)
        return s
    }

    private func updateProtocolUI() {
        let ftp = protoPopup.selectedTag() == FileProtocol.ftp.rawValue
        secLabel.isHidden = !ftp
        secPopup.isHidden = !ftp
        sessionGrid?.row(at: 4).isHidden = ftp
    }

    @objc func protocolChanged(_ sender: Any?) {
        // ポート番号が既定のままなら、プロトコルに合わせて変える
        let p = Int(portField.stringValue) ?? 0
        let proto = FileProtocol(rawValue: protoPopup.selectedTag()) ?? .sftp
        if [21, 22, 990, 0].contains(p) { portField.stringValue = String(proto == .ftp ? (secPopup.selectedTag() == FTPSecurity.implicitTLS.rawValue ? 990 : 21) : 22) }
        updateProtocolUI()
    }

    @objc func securityChanged(_ sender: Any?) {
        let p = Int(portField.stringValue) ?? 0
        if p == 21 || p == 990 { portField.stringValue = secPopup.selectedTag() == FTPSecurity.implicitTLS.rawValue ? "990" : "21" }
    }

    @objc func chooseKey(_ sender: Any?) {
        let o = NSOpenPanel()
        o.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        o.showsHiddenFiles = true
        o.message = "秘密鍵のファイルを選んでください (OpenSSH 形式)"
        guard o.runModal() == .OK, let u = o.url else { return }
        keyField.stringValue = u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: 管理

    @objc func saveSite(_ sender: Any?) {
        var s = formSite()
        guard !s.host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(hostField); return }
        let a = NSAlert()
        a.messageText = "セッションを名前を付けて保存"
        let name = UI.field(current?.name ?? SiteStore.shared.uniqueName(s.defaultName), width: 300)
        let folderPopup = NSPopUpButton()
        folderPopup.addItem(withTitle: "(なし)")
        for f in SiteStore.shared.allFolders() { folderPopup.addItem(withTitle: f) }
        let savePw = UI.checkbox("パスワードを保存する (キーチェーンに保存)", s.savePassword || current == nil && !s.password.isEmpty)
        // 名前の欄はフォルダを除いた部分
        if let c = current, !c.folder.isEmpty { name.stringValue = c.shortName; folderPopup.selectItem(withTitle: c.folder) }
        let g = UI.grid([[UI.label("サイト名:"), name], [UI.label("フォルダ:"), folderPopup], [NSView(), savePw]])
        g.frame = NSRect(x: 0, y: 0, width: 400, height: 90)
        a.accessoryView = g
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let short = name.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "／")
        guard !short.isEmpty else { return }
        let folder = folderPopup.indexOfSelectedItem > 0 ? folderPopup.titleOfSelectedItem ?? "" : ""
        s.name = SiteStore.shared.uniqueName(folder.isEmpty ? short : folder + "/" + short, except: s.id)
        s.savePassword = savePw.state == .on
        current = s
        SiteStore.shared.save(s)
        selectSite(s.id)
    }

    @objc func newSite(_ sender: Any?) {
        outline.selectRowIndexes([0], byExtendingSelection: false)
        window?.makeFirstResponder(hostField)
    }

    @objc func duplicateSite(_ sender: Any?) {
        guard let n = selectedNode, let s = n.site, var copy = SiteStore.shared.site(s.id) else { return }
        copy.id = UUID()
        copy.name = SiteStore.shared.uniqueName(s.name)
        SiteStore.shared.save(copy)
        selectSite(copy.id)
    }

    @objc func renameItem(_ sender: Any?) {
        guard let n = selectedNode, !n.isNew else { return }
        guard let new = Dialogs.input(prompt: "新しい名前:", value: n.name, title: "名前の変更", parent: window)?
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "／"), !new.isEmpty, new != n.name else { return }
        let parent = n.path.range(of: "/", options: .backwards).map { String(n.path[..<$0.lowerBound]) + "/" } ?? ""
        if n.isFolder {
            SiteStore.shared.renameFolder(n.path, to: parent + new)
        } else if let s = n.site, var full = SiteStore.shared.site(s.id) {
            full.name = SiteStore.shared.uniqueName(parent + new, except: s.id)
            SiteStore.shared.save(full)
            selectSite(s.id)
        }
    }

    @objc func deleteItem(_ sender: Any?) {
        guard let n = selectedNode, !n.isNew else { return }
        if n.isFolder {
            guard Dialogs.confirm("フォルダ '\(n.name)' とその中のサイトをすべて削除しますか?", ok: "削除") else { return }
            SiteStore.shared.deleteFolder(n.path)
        } else if let s = n.site {
            guard Dialogs.confirm("サイト '\(n.name)' を削除しますか?", ok: "削除") else { return }
            SiteStore.shared.delete(s.id)
        }
        outline.selectRowIndexes([0], byExtendingSelection: false)
    }

    @objc func newFolder(_ sender: Any?) {
        guard let name = Dialogs.input(prompt: "フォルダの名前:", value: "新しいフォルダ", title: "新しいフォルダ", parent: window)?
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "／"), !name.isEmpty else { return }
        var base = ""
        if let n = selectedNode { base = n.isFolder ? n.path : (n.site?.folder ?? "") }
        SiteStore.shared.addFolder(base.isEmpty ? name : base + "/" + name)
    }

    @objc func importIni(_ sender: Any?) {
        let o = NSOpenPanel()
        o.message = """
        Windows 版 WinSCP の設定ファイルを選んでください。
        ・WinSCP.ini (WinSCP の「ツール → 設定のエクスポート/バックアップ」で作れます)
        ・.reg (レジストリエディタで HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2 を書き出したもの)
        """
        o.allowedFileTypes = ["ini", "reg"]
        o.allowsOtherFileTypes = true
        guard o.runModal() == .OK, let u = o.url else { return }
        WinSCPImport.importFile(u)
    }

    @objc func exportIni(_ sender: Any?) {
        let sites = SiteStore.shared.sites.compactMap { SiteStore.shared.site($0.id) }
        guard !sites.isEmpty else { Dialogs.message("保存済みのサイトがありません"); return }
        let a = NSAlert()
        a.messageText = "WinSCP.ini に書き出す"
        a.informativeText = "Windows 版 WinSCP の「ツール → 設定のインポート/復元」で読み込めます。"
        let pw = UI.checkbox("保存したパスワードも含める (WinSCP と同じ簡易な暗号化のみ)", false)
        a.accessoryView = pw
        a.addButton(withTitle: "書き出す…")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let s = NSSavePanel()
        s.nameFieldStringValue = "WinSCP.ini"
        guard s.runModal() == .OK, let u = s.url else { return }
        let list = sites.map { x in
            WinSCPIni.Site(path: x.name, host: x.host, port: x.port, user: x.user,
                           password: pw.state == .on ? x.password : "", proto: x.proto, ftpSecurity: x.ftpSecurity,
                           remoteDirectory: x.remoteDirectory,
                           raw: x.settings.merging(x.localDirectory.isEmpty ? [:] : ["LocalDirectory": x.localDirectory]) { a, _ in a })
        }
        do {
            try WinSCPIni.write(list, configuration: WinSCPConfig.shared.values).write(to: u)
            Dialogs.message("\(list.count) 個のサイトを書き出しました")
        } catch { Dialogs.error(error) }
    }

    @objc func importSSHConfig(_ sender: Any?) {
        let path = NSHomeDirectory() + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path) else { Dialogs.message("~/.ssh/config がありません"); return }
        var n = 0
        for h in SSHConfig.hosts(text) where !SiteStore.shared.sites.contains(where: { $0.host == h.alias && $0.proto != .ftp }) {
            var s = Site()
            s.name = SiteStore.shared.uniqueName("ssh config/" + h.alias)
            // ssh の設定どおりに接続させるため、ホスト名には別名をそのまま使う
            s.host = h.alias
            s.port = 22
            SiteStore.shared.save(s)
            n += 1
        }
        Dialogs.message("\(n) 個のホストを読み込みました", "フォルダ「ssh config」に入れました。ホスト名・ユーザー・鍵は ~/.ssh/config の設定が使われます。")
    }

    // MARK: ログイン

    @objc func login(_ sender: Any?) {
        guard connecting == nil else { return }
        let s = formSite()
        guard !s.host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(hostField); return }
        // 保存済みサイトの内容を変えたまま接続するときは、それを保存しておく (パスワード以外)
        if let c = current, c != s, SiteStore.shared.sites.contains(where: { $0.id == c.id }) {
            var keep = s
            if !c.savePassword { keep.password = "" }
            SiteStore.shared.save(keep)
        }
        if let c = current { UserDefaults.standard.set(c.id.uuidString, forKey: "LastSite") }
        let session = Session(site: s)
        connecting = session
        setBusy(true)
        session.connect(parent: { [weak self] in self?.window }) { [weak self] err in
            guard let self = self else { return }
            self.connecting = nil
            self.setBusy(false)
            if let e = err {
                if !((e as? RemoteError)?.isCancelled ?? false) { Dialogs.error(e, title: "\(s.displayAddress) に接続できません") }
                return
            }
            self.openCommander(session)
        }
    }

    func openCommander(_ session: Session) {
        let c = CommanderWindowController(session: session)
        // 開いているセッションがあれば、そのウインドウのタブに加える
        if let host = NSApp.keyWindow?.windowController as? CommanderWindowController ?? CommanderWindowController.all.first(where: { $0 !== c }),
           let hw = host.window, let w = c.window {
            hw.addTabbedWindow(w, ordered: .above)
        }
        c.showWindow(nil)
        c.start()
        window?.orderOut(nil)
    }

    private func setBusy(_ b: Bool) {
        if b { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        loginButton.title = b ? "接続中…" : "ログイン"
        loginButton.isEnabled = !b
    }

    @objc func closeWindow(_ sender: Any?) {
        if let c = connecting { c.cancelConnect(); return }
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        connecting?.cancelConnect()
        // セッションが無ければアプリを終わる (WinSCP と同じ)
        if CommanderWindowController.all.isEmpty && !NSApp.isTerminatingFlag {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension SiteStore {
    func allFolders() -> [String] {
        var set = Set(folders)
        for s in sites where !s.folder.isEmpty {
            var parts: [String] = []
            for p in s.folder.split(separator: "/") { parts.append(String(p)); set.insert(parts.joined(separator: "/")) }
        }
        return set.sorted()
    }
}

/// ~/.ssh/config の Host を読む (ワイルドカードは除く)
enum SSHConfig {
    struct Host { let alias: String }
    static func hosts(_ text: String) -> [Host] {
        var out: [Host] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("host ") || line.lowercased().hasPrefix("host\t") else { continue }
            for a in line.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let s = String(a)
                if s.contains("*") || s.contains("?") || s.hasPrefix("!") { continue }
                out.append(Host(alias: s))
            }
        }
        return out
    }
}

/// Windows 版 WinSCP の設定の取り込み
enum WinSCPImport {
    static func importFile(_ u: URL) {
        guard let d = try? Data(contentsOf: u) else { Dialogs.message("\(u.lastPathComponent) を読めません"); return }
        let r = WinSCPIni.read(d)
        if r.sites.isEmpty && r.configuration.isEmpty {
            Dialogs.message("サイトが見つかりませんでした", r.notes.joined(separator: "\n"))
            return
        }
        let n = SiteStore.shared.importWinSCP(r)
        let conf = r.configuration.keys.filter { $0.hasPrefix("Configuration\\") }.count
        WinSCPConfig.shared.merge(r.configuration)
        Dialogs.message("\(n) 個のサイトを読み込みました", ([conf > 0 ? "環境設定 \(conf) 項目も引き継ぎました。" : ""] + r.notes).filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// 初めて起動したとき、ダウンロード・デスクトップ・書類に WinSCP.ini があれば読み込むか聞く
    static func offerOnFirstLaunch() {
        let key = "OfferedWinSCPImport"
        guard !UserDefaults.standard.bool(forKey: key), SiteStore.shared.sites.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory] {
            guard let base = fm.urls(for: dir, in: .userDomainMask).first,
                  let names = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for n in names where n.lowercased().hasPrefix("winscp") && (n.lowercased().hasSuffix(".ini") || n.lowercased().hasSuffix(".reg")) {
                let u = base.appendingPathComponent(n)
                if let d = try? Data(contentsOf: u), !WinSCPIni.read(d).sites.isEmpty { found.append(u) }
            }
        }
        guard let u = found.first else { return }
        let a = NSAlert()
        a.messageText = "Windows 版 WinSCP の設定が見つかりました"
        a.informativeText = "\(u.path)\n\nこのファイルのサイトを読み込みますか?"
        a.addButton(withTitle: "読み込む")
        a.addButton(withTitle: "読み込まない")
        if a.runModal() == .alertFirstButtonReturn { importFile(u) }
    }
}
