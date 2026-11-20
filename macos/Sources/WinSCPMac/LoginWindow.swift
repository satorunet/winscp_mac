import AppKit
import ScpCore

/// ログイン画面。WinSCP の Login.dfm をそのまま組み立て、Login.cpp と同じ動きにする。
/// 左: サイトの木 (新しいサイト / フォルダ / サイト)、右: セッションの欄
final class LoginWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = LoginWindowController()

    /// 木の項目
    final class Node {
        let name: String
        let path: String
        let site: Site?
        var children: [Node] = []
        let isNew: Bool
        init(name: String, path: String, site: Site?, isNew: Bool = false) { self.name = name; self.path = path; self.site = site; self.isNew = isNew }
        var isFolder: Bool { site == nil && !isNew }
    }

    let form: DFMForm
    private var roots: [Node] = []
    private let newNode = Node(name: Translations.shared.string("LOGIN_NEW_SITE_NODE", "新しいサイト"), path: "", site: nil, isNew: true)
    private var outline: NSOutlineView!
    private var connecting: Session?
    private var current: Site?
    /// 保存済みサイトを編集中 (WinSCP の FEditing)。新しいサイトは常に編集中
    private var editing = false
    private let spinner = NSProgressIndicator()
    private var loading = false

    // 転送プロトコルの選択肢 (WinSCP と同じ並び。WebDAV と S3 は未対応)
    private static let protoItems: [(String, FileProtocol?)] = [("SFTP", .sftp), ("SCP", .scp), ("FTP", .ftp), ("WebDAV", nil), ("Amazon S3", nil)]

    init() {
        guard let f = DFMForm("Login.dfm") else { fatalError("Login.dfm がありません") }
        form = f
        let w = NSWindow(contentRect: f.view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = f.caption
        w.contentView = f.view
        if let mw = f.root.int("Constraints.MinWidth"), let mh = f.root.int("Constraints.MinHeight") {
            w.contentMinSize = NSSize(width: mw, height: mh)
        }
        super.init(window: w)
        w.delegate = self
        setup()
        reloadTree()
        NotificationCenter.default.addObserver(self, selector: #selector(sitesChanged), name: SiteStore.changed, object: nil)
        w.setFrameAutosaveName("LoginDialog")
        if !w.setFrameUsingName("LoginDialog") { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var hostField: NSTextField { form.field("HostNameEdit")! }
    private var userField: NSTextField { form.field("UserNameEdit")! }
    private var passField: NSTextField { form.field("PasswordEdit")! }
    private var portField: NumberField { form.stepper("PortNumberEdit")! }
    private var protoPopup: NSPopUpButton { form.popup("TransferProtocolCombo")! }
    private var ftpsPopup: NSPopUpButton { form.popup("FtpsCombo")! }

    // MARK: 組み立て

    private func setup() {
        // サイトの木
        let scroll = form["SessionTree"] as! NSScrollView
        outline = scroll.documentView as? NSOutlineView
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(outlineDoubleClicked(_:))
        outline.rowHeight = 20
        outline.menu = NSMenu()
        outline.menu?.delegate = self.treeMenuDelegate
        form.setVisible("SitesIncrementalSearchPanel", false)

        // 転送プロトコル: WebDAV と S3 は選べない
        protoPopup.removeAllItems()
        protoPopup.menu?.autoenablesItems = false
        for (t, p) in LoginWindowController.protoItems {
            protoPopup.addItem(withTitle: t)
            protoPopup.lastItem?.isEnabled = p != nil
            if p == nil { protoPopup.lastItem?.toolTip = "Mac 版では未対応です" }
        }
        // 暗号化 (FTP)
        ftpsPopup.removeAllItems()
        ftpsPopup.addItems(withTitles: [form.items(form.object("FtpsCombo")!).first ?? "暗号化なし",
                                        Translations.shared.string("FTPS_IMPLICIT", "暗黙の TLS/SSL 暗号化"),
                                        Translations.shared.string("FTPS_EXPLICIT", "明示的な TLS/SSL 暗号化")])
        form.setVisible("WebDavsCombo", false)
        form.setVisible("WebDavsLabel", false)
        form.setVisible("BasicS3Panel", false)
        portField.minValue = 1
        portField.maxValue = 65535
        for f in [hostField, userField, passField] { f.delegate = self }

        form.onChange(["TransferProtocolCombo"]) { [weak self] in self?.protocolChanged() }
        form.onChange(["FtpsCombo"]) { [weak self] in self?.ftpsChanged() }
        form.onChange(["AnonymousLoginCheck"]) { [weak self] in self?.anonymousChanged() }

        // ボタン
        bind("LoginButton", #selector(login(_:)))
        bind("CloseButton", #selector(closeWindow(_:)))
        bind("HelpButton", #selector(help(_:)))
        bind("SaveButton", #selector(saveSession(_:)))
        bind("EditButton", #selector(editSession(_:)))
        bind("EditCancelButton", #selector(cancelEdit(_:)))
        bind("AdvancedButton", #selector(advanced(_:)))
        bind("ManageButton", #selector(showManageMenu(_:)))
        bind("ToolsMenuButton", #selector(showToolsMenu(_:)))
        form.button("ManageButton")?.title += " ▾"
        form.button("ToolsMenuButton")?.title += " ▾"
        form.button("LoginButton")?.keyEquivalent = "\r"
        form.button("CloseButton")?.keyEquivalent = "\u{1b}"

        // 「最後のセッションを閉じた後の起動時にログインを表示」
        let again = form.button("ShowAgainCheck")!
        again.state = WinSCPConfig.shared.bool("Configuration\\Interface\\ShowLoginWhenNoSession", true) ? .on : .off
        form.onChange(["ShowAgainCheck"]) {
            WinSCPConfig.shared.set("Configuration\\Interface\\ShowLoginWhenNoSession", again.state == .on)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        if let lb = form["LoginButton"] {
            spinner.frame = NSRect(x: lb.frame.minX - 24, y: lb.frame.minY + 4, width: 16, height: 16)
            spinner.autoresizingMask = lb.autoresizingMask
            lb.superview?.addSubview(spinner)
        }
        window?.initialFirstResponder = outline
    }

    private func bind(_ name: String, _ sel: Selector) {
        guard let b = form.button(name) else { return }
        b.target = self
        b.action = sel
    }

    // MARK: 木

    @objc private func sitesChanged() { reloadTree() }

    func reloadTree() {
        let expanded = Set((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Node }.filter { outline.isItemExpanded($0) }.map(\.path))
        let selectedKey = selectedNode.map { $0.site?.id.uuidString ?? "folder:" + $0.path }
        var folderNodes: [String: Node] = [:]
        var top: [Node] = []
        func folder(_ path: String) -> Node {
            if let n = folderNodes[path] { return n }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let n = Node(name: name, path: path, site: nil)
            folderNodes[path] = n
            if let r = path.range(of: "/", options: .backwards) { folder(String(path[..<r.lowerBound])).children.append(n) } else { top.append(n) }
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
        if let k = selectedKey {
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? Node, (n.site?.id.uuidString ?? "folder:" + n.path) == k {
                    outline.selectRowIndexes([r], byExtendingSelection: false); return
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.isFolder ?? false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = NSTableCellView()
        let iv = NSImageView()
        let t = NSTextField(labelWithString: n.name)
        t.font = DFMForm.font
        t.lineBreakMode = .byTruncatingTail
        if n.isNew { iv.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil) }
        else if n.isFolder { iv.image = NSImage(named: NSImage.folderName) }
        else { iv.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil) }
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

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // 編集中に別の項目へ移るときは、保存するか聞く (WinSCP の LOGIN_SAVE_EDITING)
        guard editing, current != nil, let n = item as? Node, n !== selectedNode else { return true }
        let a = NSAlert()
        a.messageText = Translations.shared.string("LOGIN_SAVE_EDITING", "サイトを編集しました。変更を保存しますか？")
        a.addButton(withTitle: "はい"); a.addButton(withTitle: "いいえ"); a.addButton(withTitle: "キャンセル")
        switch a.runModal() {
        case .alertFirstButtonReturn: saveEdited(); return true
        case .alertSecondButtonReturn: editing = false; return true
        default: return false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = selectedNode else { return }
        if n.isNew {
            current = nil
            editing = true
            fill(Site())
        } else if let s = n.site, let full = SiteStore.shared.site(s.id) {
            current = full
            editing = false
            fill(full)
        } else {
            current = nil
            editing = false
        }
        updateControls()
    }

    @objc func outlineDoubleClicked(_ sender: Any?) {
        guard let n = selectedNode else { return }
        if n.isFolder { if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) } }
        else { login(nil) }
    }

    // MARK: 欄

    private func fill(_ s: Site) {
        loading = true
        defer { loading = false }
        let idx = LoginWindowController.protoItems.firstIndex { $0.1 == s.proto } ?? 0
        protoPopup.selectItem(at: idx)
        ftpsPopup.selectItem(at: s.ftpSecurity == .implicitTLS ? 1 : (s.ftpSecurity == .explicitTLS ? 2 : 0))
        hostField.stringValue = s.host
        portField.value = s.port
        userField.stringValue = s.user
        passField.stringValue = s.password
        form.button("AnonymousLoginCheck")?.state = s.proto == .ftp && s.user == "anonymous" ? .on : .off
        form.textView("NoteMemo")?.string = s.setting("Note")
        editingSite = s
    }
    /// 「設定」で変えた詳細設定を含む、編集中の内容
    private var editingSite = Site()

    /// 欄の内容
    func formSite() -> Site {
        var s = editingSite
        if let c = current { s.id = c.id; s.name = c.name; s.savePassword = c.savePassword }
        s.proto = LoginWindowController.protoItems[max(0, protoPopup.indexOfSelectedItem)].1 ?? .sftp
        s.ftpSecurity = s.proto == .ftp ? [FTPSecurity.none, .implicitTLS, .explicitTLS][max(0, ftpsPopup.indexOfSelectedItem)] : .none
        var host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        // "user@host" と書かれたら分ける
        if user.isEmpty, let at = host.lastIndex(of: "@") { user = String(host[..<at]); host = String(host[host.index(after: at)...]) }
        s.host = host
        s.user = user
        s.port = portField.value > 0 ? portField.value : s.proto.defaultPort
        s.password = passField.stringValue
        let note = form.textView("NoteMemo")?.string ?? ""
        s.settings["Note"] = note.isEmpty ? nil : note
        return s
    }

    /// WinSCP の UpdateControls: 選んだ項目と編集中かどうかで、見せる部品を切り替える
    private func updateControls() {
        let n = selectedNode
        let isFolder = n?.isFolder ?? false
        form.setVisible("SitePanel", !isFolder)
        form.setVisible("ContentsPanel", isFolder)
        if isFolder, let n = n {
            form.object("ContentsGroupBox").map { _ in (form["ContentsGroupBox"] as? GroupBoxView)?.title = Translations.shared.string("LOGIN_SITE_FOLDER_CAPTION", "フォルダ") }
            form.field("ContentsNameEdit")?.stringValue = n.name
            form.field("ContentsNameEdit")?.isEditable = false
            func list(_ x: Node, _ indent: String) -> [String] {
                x.children.flatMap { c in [indent + c.name] + list(c, indent + "    ") }
            }
            form.textView("ContentsMemo")?.string = list(n, "").joined(separator: "\n")
            form.textView("ContentsMemo")?.isEditable = false
        }
        let ftp = protoPopup.indexOfSelectedItem == 2
        let ed = editing
        // 編集中でなければ、選択肢の代わりに読み取り専用の欄を見せる
        form.setVisible("TransferProtocolCombo", ed)
        form.setVisible("TransferProtocolView", !ed)
        form.field("TransferProtocolView")?.stringValue = protoPopup.titleOfSelectedItem ?? ""
        form.setVisible("FtpsCombo", ed && ftp)
        form.setVisible("EncryptionView", !ed && ftp)
        form.field("EncryptionView")?.stringValue = ftpsPopup.titleOfSelectedItem ?? ""
        form.setVisible("FtpsLabel", ftp)
        form.setVisible("BasicFtpPanel", ftp)
        form.setVisible("BasicSshPanel", !ftp)
        for f in [hostField, userField, passField] {
            f.isEditable = ed
            f.isSelectable = true
            f.drawsBackground = true
            f.backgroundColor = ed ? .textBackgroundColor : .windowBackgroundColor
        }
        portField.isEnabled = ed
        portField.field.isEditable = ed
        let anon = form.button("AnonymousLoginCheck")?.state == .on
        form.setEnabled("AnonymousLoginCheck", ed)
        if anon && ftp { userField.isEditable = false; passField.isEditable = false }
        form.textView("NoteMemo")?.isEditable = ed
        form.setVisible("NoteGroup", ed || !(form.textView("NoteMemo")?.string.isEmpty ?? true))
        // ボタン: 新しいサイトは「保存」、保存済みは「編集」、編集中は「保存」「キャンセル」
        let isNew = n?.isNew ?? false
        form.setVisible("SaveButton", ed)
        form.setVisible("EditButton", !ed && n?.site != nil)
        form.setVisible("EditCancelButton", ed && !isNew)
        form.setEnabled("AdvancedButton", ed)
        form.setEnabled("ManageButton", !(ed && !isNew))
        form.setEnabled("ToolsMenuButton", !(ed && !isNew))
        form.setEnabled("CloseButton", !(ed && !isNew))
        form.setEnabled("LoginButton", !isFolder || !(n?.children.isEmpty ?? true))
        form.button("LoginButton")?.keyEquivalent = ed && !isNew ? "" : "\r"
        form.button("SaveButton")?.keyEquivalent = ed && !isNew ? "\r" : ""
        form.button("EditCancelButton")?.keyEquivalent = ed && !isNew ? "\u{1b}" : ""
        form.button("CloseButton")?.keyEquivalent = ed && !isNew ? "" : "\u{1b}"
    }

    func controlTextDidChange(_ obj: Notification) {}

    private func protocolChanged() {
        guard !loading else { return }
        // ポート番号が既定のままなら、プロトコルに合わせる (WinSCP と同じ)
        let p = portField.value
        let ftp = protoPopup.indexOfSelectedItem == 2
        if [21, 22, 990, 0].contains(p) { portField.value = ftp ? (ftpsPopup.indexOfSelectedItem == 1 ? 990 : 21) : 22 }
        updateControls()
    }

    private func ftpsChanged() {
        let p = portField.value
        if p == 21 || p == 990 { portField.value = ftpsPopup.indexOfSelectedItem == 1 ? 990 : 21 }
        updateControls()
    }

    private func anonymousChanged() {
        if form.button("AnonymousLoginCheck")?.state == .on {
            userField.stringValue = "anonymous"
            passField.stringValue = ""
        }
        updateControls()
    }

    // MARK: ボタン

    @objc func editSession(_ sender: Any?) {
        guard current != nil else { return }
        editing = true
        updateControls()
        window?.makeFirstResponder(hostField)
    }

    @objc func cancelEdit(_ sender: Any?) {
        editing = false
        if let c = current, let s = SiteStore.shared.site(c.id) { fill(s) }
        updateControls()
    }

    @objc func advanced(_ sender: Any?) {
        var s = formSite()
        if SiteAdvancedDialog.run(&s, parent: window) {
            editingSite = s
            // 詳細設定で変わったもの (ローカル/リモートの場所など) を反映
            editingSite.proto = s.proto
        }
    }

    @objc func help(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://winscp.net/eng/docs/ui_login")!)
    }

    /// 保存: 新しいサイトは名前を付けて、編集中の保存済みサイトはそのまま上書き
    @objc func saveSession(_ sender: Any?) {
        if current != nil && editing { saveEdited(); return }
        saveAs()
    }

    private func saveEdited() {
        var s = formSite()
        guard !s.host.isEmpty else { NSSound.beep(); return }
        if let c = current { s.savePassword = c.savePassword || (!s.password.isEmpty && c.savePassword) }
        SiteStore.shared.save(s)
        current = SiteStore.shared.site(s.id)
        editing = false
        reloadTree()
        updateControls()
    }

    /// 「セッションの保存名」(WinSCP の SaveSessionDialog)
    private func saveAs() {
        var s = formSite()
        guard !s.host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(hostField); return }
        let T = Translations.shared
        let a = NSAlert()
        a.messageText = T.string("SAVE_SESSION_CAPTION", "セッションの保存名")
        let name = UI.field(SiteStore.shared.uniqueName(s.defaultName), width: 300)
        let folder = NSPopUpButton()
        folder.addItem(withTitle: T.string("SAVE_SESSION_ROOT_FOLDER2", "<なし>"))
        for f in SiteStore.shared.allFolders() { folder.addItem(withTitle: f) }
        if let n = selectedNode, n.isFolder { folder.selectItem(withTitle: n.path) }
        let savePw = UI.checkbox(T.string("SAVE_SESSION_PASSWORD", "パスワードを保存(推奨されません)"), false)
        savePw.isEnabled = !s.password.isEmpty
        let v = NSStackView(views: [UI.label(T.string("SAVE_SESSION_PROMPT", "セッションの保存名")), name,
                                    UI.label(T.string("SAVE_SESSION_FOLDER", "フォルダ")), folder, savePw])
        v.orientation = .vertical
        v.alignment = .leading
        v.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
        a.accessoryView = v
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let short = name.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "／")
        guard !short.isEmpty else { return }
        let f = folder.indexOfSelectedItem > 0 ? folder.titleOfSelectedItem ?? "" : ""
        s.id = UUID()
        s.name = SiteStore.shared.uniqueName(f.isEmpty ? short : f + "/" + short)
        s.savePassword = savePw.state == .on
        SiteStore.shared.save(s)
        current = SiteStore.shared.site(s.id)
        editing = false
        selectSite(s.id)
    }

    // MARK: 管理・ツールのメニュー (Login.dfm の TPopupMenu)

    @objc func showManageMenu(_ sender: NSButton) {
        let n = selectedNode
        let name = n?.isNew == true ? "ManageNewSitePopupMenu" : (n?.isFolder == true ? "ManageFolderPopupMenu" : "ManageSitePopupMenu")
        let m = form.menu(name, perform: { [weak self] in self?.perform($0) }, enabled: { [weak self] in self?.canPerform($0) ?? false })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc func showToolsMenu(_ sender: NSButton) {
        let m = form.menu("ToolsPopupMenu", perform: { [weak self] in self?.perform($0) }, enabled: { [weak self] in self?.canPerform($0) ?? false })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// 木の右クリックも「管理」と同じメニュー
    private lazy var treeMenuDelegate = TreeMenuDelegate(owner: self)
    final class TreeMenuDelegate: NSObject, NSMenuDelegate {
        weak var owner: LoginWindowController?
        init(owner: LoginWindowController) { self.owner = owner }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let o = owner else { return }
            let row = o.outline.clickedRow
            if row >= 0 { o.outline.selectRowIndexes([row], byExtendingSelection: false) }
            let n = o.selectedNode
            let name = n?.isNew == true ? "ManageNewSitePopupMenu" : (n?.isFolder == true ? "ManageFolderPopupMenu" : "ManageSitePopupMenu")
            let m = o.form.menu(name, perform: { [weak o] in o?.perform($0) }, enabled: { [weak o] in o?.canPerform($0) ?? false })
            menu.removeAllItems()
            for i in m.items { m.removeItem(i); menu.addItem(i) }
        }
    }

    /// Mac 版で使える操作
    private func canPerform(_ action: String) -> Bool {
        let n = selectedNode
        let site = n?.site != nil
        switch action {
        case "LoginAction": return !(editing && current != nil)
        case "PuttyAction": return site && n?.site?.proto != .ftp
        case "EditSessionAction": return site && !editing
        case "DeleteSessionAction", "RenameSessionAction": return (site || n?.isFolder == true) && !editing
        case "CloneToNewSiteAction": return site && !editing
        case "NewSessionFolderAction": return !editing || current == nil
        case "GenerateUrlAction2": return site || n?.isNew == true
        case "ImportSessionsAction", "ImportAction", "ExportAction", "PreferencesAction", "AboutAction", "ResetNewSessionAction", "CheckForUpdatesAction": return true
        case "SaveSessionAction": return editing
        case "SaveAsSessionAction": return true
        default: return false   // Pageant / PuTTYgen / 更新の確認 / デスクトップアイコン / 検索 など (Mac 版では未対応)
        }
    }

    private func perform(_ action: String) {
        switch action {
        case "LoginAction": login(nil)
        case "PuttyAction": if let s = current { TerminalLauncher.open(site: s, directory: s.remoteDirectory) }
        case "EditSessionAction": editSession(nil)
        case "DeleteSessionAction": deleteItem()
        case "RenameSessionAction": renameItem()
        case "CloneToNewSiteAction":
            // 「新しいサイトへ複製」: 内容を新しいサイトに写して編集を始める
            var s = formSite()
            s.id = UUID(); s.name = ""
            outline.selectRowIndexes([0], byExtendingSelection: false)
            fill(s)
            updateControls()
        case "NewSessionFolderAction": newFolder()
        case "GenerateUrlAction2": generateURL()
        case "ImportSessionsAction": importSessions()
        case "ImportAction": importIni(nil)
        case "ExportAction": exportIni(nil)
        case "PreferencesAction": (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
        case "AboutAction": (NSApp.delegate as? AppDelegate)?.showAbout(nil)
        case "CheckForUpdatesAction": Updater.shared.checkNow(nil)
        case "ResetNewSessionAction": fill(Site()); updateControls()
        case "SaveSessionAction": saveSession(nil)
        case "SaveAsSessionAction": saveAs()
        default: break
        }
    }

    private func renameItem() {
        guard let n = selectedNode, !n.isNew else { return }
        guard let new = Dialogs.input(prompt: "", value: n.name, title: Translations.clean(form.text(form.object("RenameSessionAction")!, "Caption") ?? "名前の変更"), parent: window)?
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

    private func deleteItem() {
        guard let n = selectedNode, !n.isNew else { return }
        let T = Translations.shared
        if n.isFolder {
            let count = SiteStore.shared.sites.filter { $0.name.hasPrefix(n.path + "/") }.count
            let msg = String(format: T.string("LOGIN_DELETE_SESSION_FOLDER", "セッション フォルダ '%@' の %d 個のセッションを削除しますか？").replacingOccurrences(of: "%s", with: "%@"), n.path, count)
            guard Dialogs.confirm(msg, ok: "OK") else { return }
            SiteStore.shared.deleteFolder(n.path)
        } else if let s = n.site {
            let msg = String(format: T.string("CONFIRM_DELETE_SESSION", "保存されたセッション'%@'を削除しますか？").replacingOccurrences(of: "%s", with: "%@"), s.name)
            guard Dialogs.confirm(msg, ok: "OK") else { return }
            SiteStore.shared.delete(s.id)
        }
        outline.selectRowIndexes([0], byExtendingSelection: false)
    }

    private func newFolder() {
        let T = Translations.shared
        guard let name = Dialogs.input(prompt: T.string("LOGIN_NEW_SESSION_FOLDER_PROMPT", "新しいフォルダ名:"), value: "", title: T.string("LOGIN_NEW_SESSION_FOLDER_CAPTION", "セッション フォルダを作成"), parent: window)?
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "／"), !name.isEmpty else { return }
        var base = ""
        if let n = selectedNode { base = n.isFolder ? n.path : (n.site?.folder ?? "") }
        SiteStore.shared.addFolder(base.isEmpty ? name : base + "/" + name)
    }

    /// 「セッション URL/コードの生成」の簡易版: URL を表示してコピーできるようにする
    private func generateURL() {
        let s = formSite()
        var c = URLComponents()
        c.scheme = s.proto == .ftp ? (s.ftpSecurity == .implicitTLS ? "ftps" : "ftp") : s.proto.title.lowercased()
        c.host = s.host
        if s.port != s.proto.defaultPort { c.port = s.port }
        if !s.user.isEmpty { c.user = s.user }
        c.path = s.remoteDirectory.isEmpty ? "/" : s.remoteDirectory
        let url = c.string ?? ""
        let a = NSAlert()
        a.messageText = "セッション URL"
        a.informativeText = url
        a.addButton(withTitle: "クリップボードにコピー")
        a.addButton(withTitle: "閉じる")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
    }

    /// 「サイトのインポート」: OpenSSH の設定 / WinSCP.ini から
    private func importSessions() {
        let a = NSAlert()
        a.messageText = Translations.clean(form.text(form.object("ImportSessionsAction")!, "Caption") ?? "サイトのインポート")
        a.informativeText = "インポート元を選んでください。"
        a.addButton(withTitle: "OpenSSH (~/.ssh/config)")
        a.addButton(withTitle: "WinSCP (WinSCP.ini / .reg)")
        a.addButton(withTitle: "キャンセル")
        switch a.runModal() {
        case .alertFirstButtonReturn: importSSHConfig(nil)
        case .alertSecondButtonReturn: importIni(nil)
        default: break
        }
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
        if let n = selectedNode, n.isFolder {
            // フォルダのログイン: 中のサイトをすべて開く (WinSCP と同じ)
            for s in SiteStore.shared.sites where s.name.hasPrefix(n.path + "/") {
                if let full = SiteStore.shared.site(s.id) { connect(full) }
            }
            return
        }
        if editing && current != nil { saveEdited() }
        let s = formSite()
        guard !s.host.isEmpty else { NSSound.beep(); window?.makeFirstResponder(hostField); return }
        if let c = current { UserDefaults.standard.set(c.id.uuidString, forKey: "LastSite") }
        connect(s)
    }

    private func connect(_ s: Site) {
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
        if let host = CommanderWindowController.all.first(where: { $0 !== c }), let hw = host.window, let w = c.window {
            hw.addTabbedWindow(w, ordered: .above)
        }
        c.showWindow(nil)
        c.start()
        window?.orderOut(nil)
    }

    private func setBusy(_ b: Bool) {
        if b { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        form.setEnabled("LoginButton", !b)
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
