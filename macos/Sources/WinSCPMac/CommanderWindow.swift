import AppKit
import ScpCore

/// WinSCP の「コマンダー」画面: 左にローカル、右にリモートの 2 画面。
/// ツールバー・ホットキーの段・ステータスバーは ScpCommander.dfm と同じ並び、
/// メニュー・ボタンの操作は NonVisual.dfm のアクションの名前で受ける (winscpAction)
final class CommanderWindowController: NSWindowController, NSWindowDelegate, FilePanelDelegate, NSToolbarDelegate, NSMenuItemValidation {
    static var all: [CommanderWindowController] = []

    let session: Session
    let local = FilePanel(remote: false)
    let remote = FilePanel(remote: true)
    private(set) var activePanel: FilePanel
    private let editors = EditManager()
    private var closing = false

    // ステータスバー (ScpCommander.dfm の StatusBar: メッセージ | プロトコル | 鍵 | 接続時間)
    private let noteLabel = NSTextField(labelWithString: "")
    private let protocolLabel = NSTextField(labelWithString: "")
    private let lockView = NSImageView()
    private let durationLabel = NSTextField(labelWithString: "")
    private var statusBar: NSView!
    /// ホットキーの段 (BottomDock の Toolbar2Toolbar: F2 名前の変更 … F10 終了)
    private var hotkeyBar: NSStackView!
    private var hotkeyButtons: [(item: String, button: ActionButton)] = []
    /// ツールバー (コマンド / 設定 / 転送設定 / 更新 / セッションとタブ / 並べ替え) の画面
    private var bandViews: [String: NSView] = [:]
    private var transferPopup: NSPopUpButton?
    private var connectedAt = Date()
    private var idleTimer: Timer?

    var otherPanel: FilePanel { activePanel === local ? remote : local }

    init(session: Session) {
        self.session = session
        activePanel = remote
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 760, height: 420)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "WinSCPMacSession"
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("CommanderWindow")
        buildUI()
        CommanderWindowController.all.append(self)
        remote.session = session
        updateTitle()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateControls() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 組み立て

    /// ツールバーの帯: (帯の名前, ScpCommander.dfm のツールバー, 表示を切り替えるアクション, 既定で表示)。
    /// 既定の表示は WinSCP の ToolbarsLayout (WinConfiguration.cpp) と同じ
    static let mainBands: [(band: String, toolbar: String, action: String, visible: Bool)] = [
        ("Commands", "CommandsToolbar", "CommanderCommandsBandAction", true),
        ("Preferences", "PreferencesToolbar", "CommanderPreferencesBandAction", true),
        ("Transfer", "TransferToolbar", "CommanderTransferBandAction", true),
        ("Updates", "UpdatesToolbar", "CommanderUpdatesBandAction", true),
        ("Session", "SessionToolbar2", "CommanderSessionBandAction2", false),
        ("Sort", "SortToolbar", "CommanderSortBandAction", false),
        ("CustomCommands", "CustomCommandsToolbar", "CommanderCustomCommandsBandAction", false),
    ]

    static func bandVisible(_ band: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: "WinSCPBand." + band) as? Bool ?? def
    }

    private func buildUI() {
        guard let w = window else { return }
        let tb = NSToolbar(identifier: "WinSCPCommanderToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        w.toolbar = tb
        if #available(macOS 11.0, *) { w.toolbarStyle = .expanded }

        for p in [local, remote] { p.delegate = self }
        local.setTitle(Translations.clean(Translations.str("LOCAL_MENU_CAPTION")))
        remote.setTitle("\(Translations.clean(Translations.str("REMOTE_MENU_CAPTION"))): \(session.site.displayAddress)")
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(local)
        split.addArrangedSubview(remote)
        split.autosaveName = "CommanderSplit"
        split.toolTip = DFMForm.shortHint(Translations.shared.get("ScpCommander.dfm", "Splitter.Hint") ?? "")

        // ホットキーの段 (F2 名前の変更 / F4 編集 / F5 コピー / F6 移動 / F7 フォルダ作成 / F8 削除 / F9 プロパティ / F10 終了)
        hotkeyBar = NSStackView()
        hotkeyBar.distribution = .fillEqually
        hotkeyBar.spacing = 2
        hotkeyBar.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        if let t2 = WinSCPActions.shared.commander?.find("Toolbar2Toolbar") {
            for c in t2.children {
                guard let a = WinSCPMenu.actionName(c) else { continue }
                let b = ActionButton(action: a, showsText: true)
                b.bezelStyle = .recessed
                b.showsBorderOnlyWhileMouseInside = true
                b.refusesFirstResponder = true
                b.font = .systemFont(ofSize: 11)
                hotkeyButtons.append((c.name, b))
                hotkeyBar.addArrangedSubview(b)
            }
        }
        hotkeyBar.isHidden = !CommanderWindowController.bandVisible("Toolbar2", true)
        refreshHotkeys()

        // ステータスバー
        for l in [noteLabel, protocolLabel, durationLabel] {
            l.font = .systemFont(ofSize: 11)
            l.lineBreakMode = .byTruncatingTail
        }
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        protocolLabel.alignment = .center
        durationLabel.alignment = .center
        protocolLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        durationLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        lockView.widthAnchor.constraint(equalToConstant: 35).isActive = true
        lockView.imageScaling = .scaleNone
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sb = NSStackView(views: [noteLabel, spacer, ToolbarFactory.separator(), protocolLabel, ToolbarFactory.separator(),
                                     lockView, ToolbarFactory.separator(), durationLabel])
        sb.spacing = 2
        sb.edgeInsets = NSEdgeInsets(top: 1, left: 8, bottom: 2, right: 8)
        sb.isHidden = !CommanderWindowController.bandVisible("StatusBar", true)
        statusBar = sb

        let v = NSStackView(views: [split, hotkeyBar, sb])
        v.orientation = .vertical
        v.spacing = 0
        for x in [split, hotkeyBar!, sb] { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        w.contentView = v
        DispatchQueue.main.async { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
    }

    func updateTitle() {
        let p = activePanel === remote ? RemotePath.name(remote.path) : (local.path as NSString).lastPathComponent
        window?.title = "\(p.isEmpty ? "/" : p) - \(session.title) - WinSCP Mac"
        window?.tab.title = session.title
    }

    func setStatus(_ s: String) { noteLabel.stringValue = s }

    /// 接続ができてから最初の表示
    func start() {
        let site = session.site
        connectedAt = Date()
        let localStart = site.localDirectory.isEmpty ? (UserDefaults.standard.string(forKey: "LastLocalDirectory") ?? NSHomeDirectory()) : site.localDirectory
        local.navigate(FileManager.default.fileExists(atPath: (localStart as NSString).expandingTildeInPath) ? localStart : NSHomeDirectory())
        let remoteStart = site.remoteDirectory.isEmpty ? session.home : site.remoteDirectory
        remote.navigate(remoteStart) { [weak self] ok in
            guard let self = self else { return }
            if !ok && remoteStart != self.session.home { self.remote.navigate(self.session.home) }
            self.remote.focus()
        }
        // プロトコルと鍵 (WinSCP の InitStatusBar)
        let proto = session.fs?.protocolName ?? site.proto.title
        protocolLabel.stringValue = proto
        protocolLabel.toolTip = Translations.str("STATUS_PROTOCOL_HINT")
        let secure = proto != "FTP"
        lockView.image = WinSCPImages.make(WinSCPImages.pngList(file: "Glyphs.dfm", list: "SessionImages"),
                                           WinSCPImages.pngList(file: "Glyphs192.dfm", list: "SessionImages"), index: 1, size: 16)
        lockView.alphaValue = secure ? 1 : 0.3
        lockView.toolTip = secure ? Translations.fmt("STATUS_SECURE", proto == "FTPS" ? "TLS" : "SSH-2") : Translations.str("STATUS_INSECURE")
        durationLabel.toolTip = Translations.str("STATUS_DURATION_HINT")
        setStatus(Translations.str("STATUS_READY"))
        updateControls()
    }

    // MARK: ツールバー (NSToolbar: 帯ごとに 1 つの項目)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        CommanderWindowController.mainBands.filter { CommanderWindowController.bandVisible($0.band, $0.visible) }
            .map { NSToolbarItem.Identifier("band." + $0.band) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        CommanderWindowController.mainBands.map { NSToolbarItem.Identifier("band." + $0.band) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let band = String(id.rawValue.dropFirst(5))
        guard let def = CommanderWindowController.mainBands.first(where: { $0.band == band }),
              let tbo = WinSCPActions.shared.commander?.find(def.toolbar) else { return nil }
        let v = ToolbarFactory.band(tbo) { [unowned self] c in
            if c.className == "TTBXDropDownItem" { return self.makeTransferPopup(c) }
            return nil
        }
        bandViews[band] = v
        let i = NSToolbarItem(itemIdentifier: id)
        let name = Translations.shared.get("ScpCommander.dfm", tbo.path + ".Caption").map(Translations.clean) ?? band
        i.label = name
        i.paletteLabel = name
        i.view = v
        return i
    }

    /// 転送設定の選択 (TransferDropDown): デフォルト・テキスト・バイナリ … (Mac 版ではデフォルトだけ)
    private func makeTransferPopup(_ c: DFMObject) -> NSView {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.font = .systemFont(ofSize: 12)
        p.controlSize = .small
        let names = ["COPY_PARAM_DEFAULT", "COPY_PARAM_PRESET_ASCII", "COPY_PARAM_PRESET_BINARY", "COPY_PARAM_NEWER_ONLY", "COPY_PARAM_PRESET_EXCLUDE_ALL_DIR"]
        p.autoenablesItems = false
        for (i, n) in names.enumerated() {
            p.addItem(withTitle: Translations.clean(Translations.str(n)))
            p.lastItem?.isEnabled = i == 0
            if i > 0 { p.lastItem?.toolTip = WinSCPMenu.notSupported }
        }
        p.menu?.addItem(.separator())
        let pref = NSMenuItem(title: WinSCPActions.shared.caption("PresetsPreferencesAction"), action: nil, keyEquivalent: "")
        pref.isEnabled = false
        pref.toolTip = WinSCPMenu.notSupported
        p.menu?.addItem(pref)
        p.toolTip = Translations.shared.get("ScpCommander.dfm", c.path + ".Hint").map(DFMForm.shortHint)
        transferPopup = p
        return p
    }

    private func setBand(_ band: String, visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "WinSCPBand." + band)
        if band == "Toolbar2" { hotkeyBar.isHidden = !visible; return }
        if band == "StatusBar" { statusBar.isHidden = !visible; return }
        guard let tb = window?.toolbar else { return }
        let id = NSToolbarItem.Identifier("band." + band)
        if let i = tb.items.firstIndex(where: { $0.itemIdentifier == id }) {
            if !visible { tb.removeItem(at: i) }
        } else if visible {
            // WinSCP の並びの位置に入れる
            let order = CommanderWindowController.mainBands.map { "band." + $0.band }
            let pos = order.firstIndex(of: id.rawValue) ?? order.count
            let at = tb.items.filter { (order.firstIndex(of: $0.itemIdentifier.rawValue) ?? 0) < pos }.count
            tb.insertItem(withItemIdentifier: id, at: at)
        }
    }

    // MARK: ホットキーの段・状態の更新 (WinSCP の UpdateControls / アクションの OnUpdate)

    /// ホットキーの段: 「F5 ダウンロード」のように、キー + 文言 (… と & を除く)。
    /// コピー・移動は今のパネルで ダウンロード ↔ アップロード が変わる
    private func refreshHotkeys() {
        for (item, b) in hotkeyButtons {
            if item == "CurrentCopyToolbar2Item" { b.actionName = activePanel.isRemote ? "RemoteCopyAction" : "LocalCopyAction" }
            if item == "CurrentMoveToolbar2Item" { b.actionName = activePanel.isRemote ? "RemoteMoveAction" : "LocalMoveAction" }
            var cap = WinSCPActions.shared.caption(b.actionName)
            if cap.hasSuffix("...") { cap.removeLast(3) }
            if let k = WinSCPActions.shared.macKey(b.actionName) { cap = ActionButton.keyText(k.0, k.1) + " " + cap }
            b.refresh(caption: cap)
        }
    }

    /// ボタンの有効・無効を今の状態に合わせる
    func updateControls() {
        guard let w = window, w.isVisible else { return }
        refreshHotkeys()
        func walk(_ v: NSView) {
            if let b = v as? ActionButton, !b.menuOnly { b.isEnabled = validate(b.actionName).enabled }
            for s in v.subviews { walk(s) }
        }
        if let cv = w.contentView { walk(cv) }
        for v in bandViews.values { walk(v) }
        let t = Int(Date().timeIntervalSince(connectedAt))
        durationLabel.stringValue = session.fs == nil ? "" : String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        if session.fs == nil { protocolLabel.stringValue = Translations.str("STATUS_NOT_CONNECTED2") }
    }

    // MARK: パネルの代理

    func panelDidBecomeActive(_ p: FilePanel) {
        activePanel = p
        local.active = p === local
        remote.active = p === remote
        updateTitle()
        refreshHotkeys()
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
            upload(urls, to: dir, move: move, ask: Prefs.showCopyDialog, dragDrop: true)
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
        download(item.entries, from: item.dir, to: dir, move: move, ask: Prefs.showCopyDialog, dragDrop: true)
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

    /// ファイルの右クリックのメニュー (NonVisual.dfm の LocalFilePopup / RemoteFilePopup)
    func panelContextMenu(_ p: FilePanel) -> NSMenu? {
        guard let popup = WinSCPActions.shared.nonVisual?.find(p.isRemote ? "RemoteFilePopup" : "LocalFilePopup") else { return nil }
        let m = NSMenu()
        WinSCPMenu.fill(m, popup.children)
        return m
    }

    // MARK: アクション (メニュー・ツールバー・ホットキーから)

    /// アクションの名前を (対象のパネル, 中身) に分ける。
    /// "LocalParentDirAction" → (ローカル, "ParentDirAction")、"CurrentDeleteFocusedAction" → (今のパネル, "DeleteAction")
    private func resolve(_ name: String) -> (panel: FilePanel, base: String) {
        var b = name
        while let l = b.last, l.isNumber { b.removeLast() }
        var p = activePanel
        if b.hasPrefix("Local") { p = local; b.removeFirst(5) }
        else if b.hasPrefix("Remote") { p = remote; b.removeFirst(6) }
        else if b.hasPrefix("Current") { b.removeFirst(7) }
        b = b.replacingOccurrences(of: "Focused", with: "")
        // ローカルとリモートで同じキーのもの (⌘R 更新 など) は、キーで呼ばれたら今のパネルに
        if (name.hasPrefix("Local") || name.hasPrefix("Remote")), NSApp.currentEvent?.type == .keyDown,
           let k = WinSCPActions.shared.macKey(name) {
            let other = name.hasPrefix("Local") ? "Remote" + name.dropFirst(5) : "Local" + name.dropFirst(6)
            if let ok = WinSCPActions.shared.macKey(other), ok == k { p = activePanel }
        }
        return (p, b)
    }

    /// 列の表示/非表示のアクション → (パネル, 列)
    private func columnAction(_ name: String) -> (FilePanel, String)? {
        guard name.hasPrefix("ShowHide"), let r = name.range(of: "ColumnAction") else { return nil }
        var mid = String(name[name.index(name.startIndex, offsetBy: 8)..<r.lowerBound])
        let p: FilePanel
        if mid.hasPrefix("Local") { p = local; mid.removeFirst(5) } else if mid.hasPrefix("Remote") { p = remote; mid.removeFirst(6) } else { return nil }
        let ids = ["Name": "name", "Size": "size", "Type": "type", "Changed": "mtime", "Attr": "attr",
                   "Rights": "rights", "Owner": "owner", "Group": "group", "LinkTarget": "linktarget"]
        guard let id = ids[mid] else { return nil }
        return (p, id)
    }

    /// パネルのツールバー・ステータスバーの切り替え → (パネル, 帯)
    private func panelBandAction(_ name: String) -> (FilePanel, String)? {
        var b = name
        while let l = b.last, l.isNumber { b.removeLast() }
        for (pre, p) in [("CommanderLocal", local), ("CommanderRemote", remote)] where b.hasPrefix(pre) && b.hasSuffix("BandAction") {
            return (p, String(b.dropFirst(pre.count).dropLast(10)))
        }
        if b == "LocalStatusBarAction" { return (local, "StatusBar") }
        if b == "RemoteStatusBarAction" { return (remote, "StatusBar") }
        return nil
    }

    private static let sortKeys = ["SortByNameAction": "name", "SortByExtAction": "ext", "SortBySizeAction": "size",
                                   "SortByTypeAction": "type", "SortByChangedAction": "mtime", "SortByAttrAction": "attr",
                                   "SortByRightsAction": "rights", "SortByOwnerAction": "owner", "SortByGroupAction": "group"]

    /// 使えるか (enabled) と、チェックの状態 (checked: nil ならチェックなし)
    func validate(_ name: String) -> (enabled: Bool, checked: Bool?) {
        if let (p, id) = columnAction(name) {
            guard let c = p.column(id) else { return (false, false) }
            return (id != "name", !c.isHidden)
        }
        if let (p, band) = panelBandAction(name) { return (true, p.isBandVisible(band)) }
        if let b = CommanderWindowController.mainBands.first(where: { $0.action == name }) {
            return (b.band != "CustomCommands", CommanderWindowController.bandVisible(b.band, b.visible))
        }
        switch name {
        case "ToolBar2Action": return (true, !hotkeyBar.isHidden)
        case "StatusBarAction": return (true, !statusBar.isHidden)
        case "AutoSizeLocalColumnsAction", "AutoSizeRemoteColumnsAction": return (true, nil)
        default: break
        }
        let (p, base) = resolve(name)
        let connected = session.fs != nil
        let usable = !p.isRemote || connected
        let hasTargets = !targets(p).isEmpty
        if let key = CommanderWindowController.sortKeys[base] {
            let k = !p.isRemote && key == "rights" ? "attr" : key
            return (usable && p.column(k) != nil, p.sortKey == k)
        }
        switch base {
        case "ChangePathAction", "OpenDirAction", "RefreshAction", "HomeDirAction", "PathToClipboardAction",
             "SelectAction", "UnselectAction", "SelectAllAction", "InvertSelectionAction", "ClearSelectionAction",
             "NewFileAction", "NewDirAction", "CreateDirAction":
            return (usable, nil)
        case "ParentDirAction", "RootDirAction": return (usable && p.path != "/", nil)
        case "BackAction": return (usable && p.canGoBack, nil)
        case "ForwardAction": return (usable && p.canGoForward, nil)
        case "ExploreDirectoryAction": return (!p.isRemote, nil)
        case "ReportAction": return (true, true)
        case "SortAscendingAction": return (usable, p.sortAscending)
        case "SelectSameExtAction", "UnselectSameExtAction":
            return (usable && p.focusedEntry.map { $0.name != ".." && !$0.isDirectory } == true, nil)
        case "OpenAction", "EditAction":
            return (usable && p.focusedEntry.map { $0.name != ".." && (base == "OpenAction" || !$0.isDirectory) } == true, nil)
        case "CopyAction", "CopyNonQueueAction", "MoveAction", "DeleteAction", "PropertiesAction",
             "FileListToClipboardAction", "FullFileListToClipboardAction":
            return (connected && hasTargets, nil)
        case "RenameAction": return (usable && p.focusedEntry.map { $0.name != ".." } == true, nil)
        case "CompareDirectoriesAction", "ClearCachesAction": return (connected, nil)
        case "ConsoleAction": return (connected, nil)
        case "PuttyAction": return (connected && session.site.proto != .ftp, nil)
        case "CloseApplicationAction", "CloseTabAction", "DisconnectSessionAction", "DuplicateTabAction": return (true, nil)
        default: return (false, nil)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(winscpAction(_:)) {
            // ファイル → コピー: 今のパネルで ダウンロード ↔ アップロード (ScpCommander.cpp の UpdateControls と同じ)
            DynamicMenuDelegate.update(item, remote: activePanel.isRemote)
            guard let a = item.representedObject as? String else { return false }
            let v = validate(a)
            item.state = v.checked == true ? .on : .off
            return v.enabled
        }
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

    @objc func winscpAction(_ sender: Any?) {
        guard let name = WinSCPAction.name(sender) else { return }
        perform(name)
    }

    /// アクションを実行する
    func perform(_ name: String) {
        if let (p, id) = columnAction(name) {
            if let c = p.column(id), id != "name" { c.isHidden.toggle() }
            return
        }
        if let (p, band) = panelBandAction(name) { p.setBand(band, visible: !p.isBandVisible(band)); return }
        if let b = CommanderWindowController.mainBands.first(where: { $0.action == name }) {
            setBand(b.band, visible: !CommanderWindowController.bandVisible(b.band, b.visible))
            return
        }
        switch name {
        case "ToolBar2Action": setBand("Toolbar2", visible: hotkeyBar.isHidden); return
        case "StatusBarAction": setBand("StatusBar", visible: statusBar.isHidden); return
        case "AutoSizeLocalColumnsAction": local.autoSizeColumns(); return
        case "AutoSizeRemoteColumnsAction": remote.autoSizeColumns(); return
        default: break
        }
        guard validate(name).enabled else { NSSound.beep(); return }
        let (p, base) = resolve(name)
        if let key = CommanderWindowController.sortKeys[base] {
            p.sort(by: !p.isRemote && key == "rights" ? "attr" : key)
            return
        }
        switch base {
        case "ChangePathAction": p.focusPath()
        case "OpenDirAction": openDirectory(p)
        case "ExploreDirectoryAction": NSWorkspace.shared.open(URL(fileURLWithPath: p.path))
        case "ParentDirAction": p.goUp(nil)
        case "RootDirAction": p.goRoot(nil)
        case "HomeDirAction": p.goHome(nil)
        case "BackAction": p.goBack(nil)
        case "ForwardAction": p.goForward(nil)
        case "RefreshAction": p.reload()
        case "PathToClipboardAction":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.path, forType: .string)
        case "ReportAction": break
        case "SortAscendingAction": p.toggleSortAscending()
        case "SelectAction", "UnselectAction": selectByMask(p, select: base == "SelectAction")
        case "SelectAllAction": p.selectAll()
        case "InvertSelectionAction":
            let sel = Set(p.selectedEntries.map(\.name))
            p.select(names: p.entries.filter { $0.name != ".." && !sel.contains($0.name) }.map(\.name))
        case "ClearSelectionAction": p.table.deselectAll(nil)
        case "SelectSameExtAction", "UnselectSameExtAction":
            guard let f = p.focusedEntry else { return }
            let ext = (f.name as NSString).pathExtension
            let same = p.entries.filter { !$0.isDirectory && ($0.name as NSString).pathExtension == ext }.map(\.name)
            var cur = Set(p.selectedEntries.map(\.name))
            if base == "SelectSameExtAction" { cur.formUnion(same) } else { cur.subtract(same) }
            p.select(names: Array(cur))
        case "NewFileAction": newFile(p)
        case "NewDirAction", "CreateDirAction": makeFolder(in: p)
        case "OpenAction": p.openFocused()
        case "EditAction": edit(p)
        case "CopyAction", "CopyNonQueueAction": transfer(from: p, move: false)
        case "MoveAction": transfer(from: p, move: true)
        case "DeleteAction": delete(in: p)
        case "RenameAction": rename(in: p)
        case "PropertiesAction": properties(in: p)
        case "FileListToClipboardAction", "FullFileListToClipboardAction":
            let names = targets(p).map { base.hasPrefix("Full") ? p.join($0.name) : $0.name }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        case "CompareDirectoriesAction": compareDirectories(nil)
        case "ClearCachesAction": remote.reload()
        case "ConsoleAction": runCommand(nil)
        case "PuttyAction": openTerminal(nil)
        case "CloseApplicationAction": NSApp.terminate(nil)
        case "CloseTabAction", "DisconnectSessionAction": closeSession(nil)
        case "DuplicateTabAction": duplicateTab()
        default: NSSound.beep()
        }
    }

    // MARK: 操作

    @objc func switchPanel(_ sender: Any?) { otherPanel.focus() }

    @objc func refreshPanels(_ sender: Any?) { activePanel.reload() }

    @objc func toggleHidden(_ sender: Any?) {
        Prefs.showHidden.toggle()
        for c in CommanderWindowController.all { c.local.applyFilterAndSort(); c.remote.applyFilterAndSort() }
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

    @objc func copyFiles(_ sender: Any?) { transfer(from: activePanel, move: false) }
    @objc func moveFiles(_ sender: Any?) { transfer(from: activePanel, move: true) }

    private func transfer(from p: FilePanel, move: Bool) {
        let items = targets(p)
        guard !items.isEmpty else { return }
        if p.isRemote {
            download(items, from: p.path, to: local.path, move: move, ask: Prefs.showCopyDialog)
        } else {
            upload(items.map { URL(fileURLWithPath: p.join($0.name)) }, to: remote.path, move: move, ask: Prefs.showCopyDialog)
        }
    }

    func upload(_ urls: [URL], to dir: String, move: Bool, ask: Bool, dragDrop: Bool = false) {
        guard !urls.isEmpty else { return }
        var target = dir
        if ask {
            guard let t = CopyDialog.run(upload: true, move: move, names: urls.map(\.lastPathComponent), target: dir,
                                         dragDrop: dragDrop, parent: window) else { return }
            target = t
        }
        let job = TransferJob(session: session, upload: urls, to: target, move: move)
        job.start(parent: window) { [weak self] names, err in
            guard let self = self else { return }
            if let e = err { Dialogs.error(e) }
            self.remote.reload(select: target == self.remote.path ? names : nil)
            if move { self.local.reload() }
            if err == nil { self.setStatus(Translations.str("IDS_STATUSMSG_UPLOADSUCCESSFUL")) }
        }
    }

    func download(_ entries: [FileEntry], from dir: String, to localDir: String, move: Bool, ask: Bool, dragDrop: Bool = false) {
        guard !entries.isEmpty else { return }
        var target = localDir
        if ask {
            guard let t = CopyDialog.run(upload: false, move: move, names: entries.map(\.name), target: localDir,
                                         dragDrop: dragDrop, parent: window) else { return }
            target = (t as NSString).expandingTildeInPath
        }
        let job = TransferJob(session: session, download: entries, from: dir, to: target, move: move)
        job.start(parent: window) { [weak self] names, err in
            guard let self = self else { return }
            if let e = err { Dialogs.error(e) }
            self.local.reload(select: target == self.local.path ? names : nil)
            if move { self.remote.reload() }
            if err == nil { self.setStatus(Translations.str("IDS_STATUSMSG_DOWNLOADSUCCESSFUL")) }
        }
    }

    @objc func renameFile(_ sender: Any?) { rename(in: activePanel) }

    private func rename(in p: FilePanel) {
        guard let e = p.focusedEntry, e.name != ".." else { return }
        guard let n = Dialogs.input(prompt: Translations.clean(Translations.str("RENAME_PROMPT2")), value: e.name,
                                    title: WinSCPActions.shared.caption("CurrentRenameAction"), parent: window),
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

    @objc func makeFolder(_ sender: Any?) { makeFolder(in: activePanel) }

    /// フォルダの作成 (CreateDirectory.dfm)
    private func makeFolder(in p: FilePanel) {
        guard let r = CreateDirectoryDialog.run(remote: p.isRemote, parent: window), !r.name.isEmpty else { return }
        let path = r.name.hasPrefix("/") ? r.name : p.join(r.name)
        let first = (r.name as NSString).pathComponents.first ?? r.name
        if p.isRemote {
            session.run({ fs in
                try fs.makeDirectory(path)
                if let m = r.mode { try fs.setPermissions(path, m) }
            }) { res in
                if case .failure(let err) = res { Dialogs.error(err) }
                p.reload(select: [first])
            }
        } else {
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            catch { Dialogs.error(Translations.fmt("CREATE_LOCAL_DIR_ERROR", path), error) }
            p.reload(select: [first])
        }
    }

    /// 新しいファイル (Shift+F4): 空のファイルを作って編集する
    private func newFile(_ p: FilePanel) {
        guard let n = Dialogs.input(prompt: Translations.clean(WinSCPActions.shared.caption("NewFileAction")),
                                    value: Translations.str("NEW_FILE"), title: WinSCPActions.shared.caption("NewFileAction"), parent: window),
              !n.isEmpty else { return }
        if p.isRemote {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: tmp.path, contents: Data())
            session.run({ fs in try fs.upload(tmp, to: p.join(n)) { _ in true } }) { [weak self] r in
                try? FileManager.default.removeItem(at: tmp)
                if case .failure(let e) = r { Dialogs.error(e); return }
                p.reload(select: [n]) {
                    if let e = p.entries.first(where: { $0.name == n }) { self?.editRemote(e) }
                }
            }
        } else {
            let path = p.join(n)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data()) }
            p.reload(select: [n])
            EditManager.openInEditor(URL(fileURLWithPath: path))
        }
    }

    @objc func deleteFiles(_ sender: Any?) { delete(in: activePanel) }

    private func delete(in p: FilePanel) {
        let items = targets(p)
        guard !items.isEmpty else { return }
        // ゴミ箱へ入れるときは「ファイルをゴミ箱へ移動時に確認する」(ConfirmRecycling) を使う
        let confirm = p.isRemote ? Prefs.confirmDelete : Prefs.confirmRecycle
        if confirm {
            // WinSCP の削除の確認 (CONFIRM_DELETE_FILE / CONFIRM_DELETE_FILES、「次回は表示しない」付き)
            let msg = items.count == 1 ? Translations.fmt("CONFIRM_DELETE_FILE", items[0].name) : Translations.fmt("CONFIRM_DELETE_FILES", items.count)
            let a = NSAlert()
            a.messageText = Translations.str("Vcl_Consts_SMsgDlgConfirm")
            a.informativeText = msg
            a.alertStyle = .warning
            a.addButton(withTitle: Translations.clean(Translations.str("Vcl_Consts_SMsgDlgOK")))
            a.addButton(withTitle: Translations.clean(Translations.str("Vcl_Consts_SMsgDlgCancel")))
            a.showsSuppressionButton = true
            a.suppressionButton?.title = Translations.clean(Translations.str("NEVER_ASK_AGAIN"))
            let r = a.runModal()
            if r != .alertFirstButtonReturn { return }
            if a.suppressionButton?.state == .on {
                if p.isRemote { Prefs.confirmDelete = false } else { Prefs.confirmRecycle = false }
            }
        }
        if p.isRemote {
            RemoteDelete.run(session: session, dir: p.path, entries: items, parent: window) { err in
                if let e = err { Dialogs.error(e) }
                p.reload()
            }
        } else {
            NSWorkspace.shared.recycle(items.map { URL(fileURLWithPath: p.join($0.name)) }) { _, err in
                if let e = err { Dialogs.error(e) }
                p.reload()
            }
        }
    }

    @objc func editFile(_ sender: Any?) { edit(activePanel) }

    private func edit(_ p: FilePanel) {
        guard let e = p.focusedEntry, e.name != "..", !e.isDirectory else { return }
        if p.isRemote { editRemote(e) } else { EditManager.openInEditor(URL(fileURLWithPath: p.join(e.name))) }
    }

    private func editRemote(_ e: FileEntry) {
        editors.edit(session: session, dir: remote.path, entry: e, parent: window) { [weak self] msg in
            self?.setStatus(msg)
            self?.remote.reload()
        }
    }

    @objc func showProperties(_ sender: Any?) { properties(in: activePanel) }

    /// プロパティ (Properties.dfm)。パーミッションを変えたら (必要なら中身も) 設定する
    private func properties(in p: FilePanel) {
        let items = targets(p)
        guard !items.isEmpty else { return }
        PropertiesDialog.run(entries: items, dir: p.path, remote: p.isRemote, parent: window) { [weak self] change, recursive in
            guard let self = self else { return }
            if p.isRemote {
                self.session.run({ fs in
                    func apply(_ path: String, _ e: FileEntry) throws {
                        try fs.setPermissions(path, change.apply(e.permissions ?? 0, isDirectory: e.isDirectory))
                        if recursive && e.isDirectory {
                            for c in try fs.list(path) where !c.isSymlink { try apply(RemotePath.join(path, c.name), c) }
                        }
                    }
                    for e in items { try apply(p.join(e.name), e) }
                }) { r in
                    if case .failure(let e) = r { Dialogs.error(e) }
                    p.reload()
                }
            } else {
                let fm = FileManager.default
                func apply(_ path: String) throws {
                    let a = try fm.attributesOfItem(atPath: path)
                    let old = (a[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
                    let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
                    try fm.setAttributes([.posixPermissions: NSNumber(value: change.apply(old, isDirectory: isDir))], ofItemAtPath: path)
                    if recursive && isDir {
                        for c in try fm.contentsOfDirectory(atPath: path) { try apply((path as NSString).appendingPathComponent(c)) }
                    }
                }
                for e in items {
                    do { try apply(p.join(e.name)) } catch { Dialogs.error(error); break }
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
        if l.isEmpty && r.isEmpty { Dialogs.message(Translations.str("COMPARE_NO_DIFFERENCES")) }
    }

    /// マスクで選択 / 選択の解除 (SelectMask.dfm)
    private func selectByMask(_ p: FilePanel, select: Bool) {
        guard let form = DFMForm("SelectMask.dfm") else { return }
        for n in ["ClearButton", "ColorButton", "ColorFileNamesLabel", "ColorSizesLabel", "ColorPaddingLabel", "MaskButton", "HintText", "HelpButton"] {
            form.setVisible(n, false)
        }
        // 色の見本の分だけ縮める (SelectMask.cpp と同じ)
        form.view.setFrameSize(NSSize(width: form.view.frame.width, height: form.view.frame.height - (77 + 47 - (54 + 17))))
        let key = "WinSCPSelectMask"
        form.combo("MaskEdit")?.stringValue = UserDefaults.standard.string(forKey: key) ?? "*.*"
        form.button("ApplyToDirectoriesCheck")?.state = .off
        guard form.runModal(title: Translations.str(select ? "SELECT_MASK_SELECT_CAPTION" : "SELECT_MASK_DESELECT_CAPTION"), parent: window) == "OKBtn",
              let mask = form.combo("MaskEdit")?.stringValue else { return }
        UserDefaults.standard.set(mask, forKey: key)
        let dirs = form.button("ApplyToDirectoriesCheck")?.state == .on
        let masks = mask.components(separatedBy: CharacterSet(charactersIn: ";,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func match(_ n: String) -> Bool {
            masks.contains { m in
                let mm = m == "*.*" ? "*" : m
                return fnmatch(mm, n, 0) == 0
            }
        }
        let hit = p.entries.filter { $0.name != ".." && (dirs || !$0.isDirectory) && match($0.name) }.map(\.name)
        var cur = Set(p.selectedEntries.map(\.name))
        if select { cur.formUnion(hit) } else { cur.subtract(hit) }
        p.select(names: Array(cur))
    }

    /// ディレクトリを開く (Ctrl+O)
    private func openDirectory(_ p: FilePanel) {
        guard let d = Dialogs.input(prompt: Translations.clean(Translations.shared.get("OpenDirectory.dfm", "EditLabel.Caption") ?? "ディレクトリを開く"),
                                    value: p.path, title: WinSCPActions.shared.caption(p.isRemote ? "RemoteOpenDirAction" : "LocalOpenDirAction"), parent: window)
        else { return }
        p.navigate(d)
    }

    /// タブの複製: 同じサイトにもう 1 つつなぐ
    private func duplicateTab() {
        let s = Session(site: session.site)
        s.connect(parent: { [weak self] in self?.window }) { [weak self] err in
            if let e = err { Dialogs.error(e); return }
            let c = CommanderWindowController(session: s)
            if let w = self?.window, let nw = c.window { w.addTabbedWindow(nw, ordered: .above) }
            c.showWindow(nil)
            c.start()
        }
    }

    @objc func runCommand(_ sender: Any?) {
        CommandWindow.show(session: session, directory: remote.path) { [weak self] in self?.remote.reload() }
    }

    @objc func openTerminal(_ sender: Any?) {
        TerminalLauncher.open(site: session.site, directory: remote.path)
    }

    @objc func goToRemote(_ sender: Any?) { openDirectory(activePanel) }

    @objc func closeSession(_ sender: Any?) { window?.performClose(sender) }

    // MARK: ウインドウ

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        if editors.hasPending, !Dialogs.confirm("編集中のファイルがあります", "セッションを閉じると、これ以降の変更はアップロードされません。閉じますか?", ok: "閉じる") {
            return false
        }
        if Prefs.confirmDisconnect && session.fs != nil && !NSApp.isTerminatingFlag {
            let a = NSAlert()
            a.messageText = Translations.str("Vcl_Consts_SMsgDlgConfirm")
            a.informativeText = Translations.fmt("CLOSE_SESSION", session.title)
            a.addButton(withTitle: Translations.clean(Translations.str("Vcl_Consts_SMsgDlgOK")))
            a.addButton(withTitle: Translations.clean(Translations.str("Vcl_Consts_SMsgDlgCancel")))
            a.showsSuppressionButton = true
            a.suppressionButton?.title = Translations.clean(Translations.str("NEVER_ASK_AGAIN"))
            let r = a.runModal()
            if a.suppressionButton?.state == .on { Prefs.confirmDisconnect = false }
            if r != .alertFirstButtonReturn { return false }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        idleTimer?.invalidate()
        UserDefaults.standard.set(local.path, forKey: "LastLocalDirectory")
        editors.stopAll()
        session.close()
        CommanderWindowController.all.removeAll { $0 === self }
        if CommanderWindowController.all.isEmpty && !NSApp.isTerminatingFlag {
            // 「最後のセッションを閉じた後の起動時にログインを表示」が切ってあれば終了する (WinSCP と同じ)
            if WinSCPConfig.shared.bool("Configuration\\Interface\\ShowLoginWhenNoSession", true) {
                DispatchQueue.main.async { LoginWindowController.shared.showWindow(nil) }
            } else {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateTitle() }
}

extension NSApplication {
    /// 終了処理中か (終了時は確認を出さない)
    var isTerminatingFlag: Bool { (delegate as? AppDelegate)?.terminating ?? false }
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
