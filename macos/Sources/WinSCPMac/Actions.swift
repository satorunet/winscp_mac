import AppKit

/// WinSCP のアクション (NonVisual.dfm の ExplorerActions)。
/// メニュー・ツールバー・ホットキーの文言・絵・ショートカットはすべてここから取る
final class WinSCPActions {
    static let shared = WinSCPActions()

    let nonVisual: DFMObject?
    /// コマンダーの画面 (ScpCommander.dfm): メニューとツールバーの並び
    let commander: DFMObject?
    private var actions: [String: DFMObject] = [:]
    private let tr = Translations.shared

    init() {
        nonVisual = DFMForm.parseFile("NonVisual.dfm")
        commander = DFMForm.parseFile("ScpCommander.dfm")
        if let al = nonVisual?.find("ExplorerActions") { for a in al.children { actions[a.name] = a } }
    }

    func exists(_ n: String) -> Bool { actions[n] != nil }

    /// 訳 (アクセラレータ付きのまま)
    private func raw(_ n: String, _ prop: String) -> String? {
        guard let a = actions[n] else { return nil }
        if let t = tr.get("NonVisual.dfm", a.path + "." + prop) { return Translations.unescape(t) }
        return a.str(prop)
    }

    /// メニューに出す文言 ((&D) などを除く)
    func caption(_ n: String) -> String {
        if let c = raw(n, "Caption"), !c.isEmpty { return Translations.clean(c) }
        // 文言の無いアクション (速度の欄など) はヒント
        let h = hint(n).short
        return h.isEmpty ? n : Translations.clean(h)
    }

    /// ヒント: 短いほう (ツールチップ) と長いほう (ステータスバー)
    func hint(_ n: String) -> (short: String, long: String) {
        let h = raw(n, "Hint") ?? ""
        if let i = h.firstIndex(of: "|") {
            let s = String(h[..<i]), l = String(h[h.index(after: i)...])
            return (s.isEmpty ? l : s, l)
        }
        return (h, h)
    }

    func imageIndex(_ n: String) -> Int? { actions[n]?.int("ImageIndex") }
    func image(_ n: String) -> NSImage? { imageIndex(n).flatMap { WinSCPImages.explorer($0) } }
    func isChecked(_ n: String) -> Bool { actions[n]?.bool("Checked") == true }

    /// ショートカット (VCL の TShortCut)。コマンダーでの割り当て (NonVisual.cpp の CommanderShortcuts) を優先
    func shortcut(_ n: String) -> Int {
        if let s = WinSCPActions.commanderShortcuts[n] { return s }
        return actions[n]?.int("ShortCut") ?? 0
    }

    // MARK: ショートカット

    static let shiftMask = 0x2000, ctrlMask = 0x4000, altMask = 0x8000
    static func F(_ n: Int) -> Int { 0x6F + n }

    /// NonVisual.cpp の CommanderShortcuts() と CloneShortcuts() の写し
    static let commanderShortcuts: [String: Int] = {
        let ctrl = ctrlMask, alt = altMask, shift = shiftMask
        func key(_ c: Character) -> Int { Int(c.asciiValue ?? 0) }
        var d: [String: Int] = [
            "CurrentCreateDirAction": F(7),
            "CurrentRenameAction": F(2),
            "CurrentEditAction": F(4),
            "CurrentAddEditLinkAction": alt | F(6),
            "CurrentEditInternalAction": ctrl | alt | F(4),
            "CurrentEditInternalFocusedAction": ctrl | alt | F(4),
            "RemoteCopyAction": F(5),
            "RemoteMoveAction": F(6),
            "CurrentDeleteFocusedAction": F(8),
            "CurrentPropertiesFocusedAction": F(9),
            "RemoteMoveToFocusedAction": shift | F(6),
            "RemoteCopyToFocusedAction": shift | F(5),
            "RemoteOpenDirAction": ctrl | key("O"),
            "RemoteRefreshAction": ctrl | key("R"),
            "RemoteHomeDirAction": ctrl | key("H"),
            "RemotePathToClipboardAction2": ctrl | 0xDD,
            "LocalPathToClipboardAction2": ctrl | 0xDB,
            "CurrentDeleteAlternativeAction": shift | F(8),
            "RemoteMoveToAction": shift | F(6),
            "RemoteCopyToAction": shift | F(5),
            "SelectOneAction": 0x2D,
            "NewFileAction": shift | F(4),
            "RemoteFindFilesAction2": alt | F(7),
            "NewTabAction": ctrl | key("T"),
            "CloseApplicationAction2": F(10),
            "LocalSortByExtAction2": ctrl | F(4),
            "RemoteSortByExtAction2": ctrl | F(4),
            "CurrentSortByExtAction": ctrl | F(4),
        ]
        // CloneShortcuts
        let clone: [(String, String)] = [
            ("NewDirAction", "CurrentCreateDirAction"),
            ("CurrentAddEditLinkContextAction", "CurrentAddEditLinkAction"),
            ("LocalAddEditLinkAction3", "CurrentAddEditLinkAction"),
            ("RemoteAddEditLinkAction3", "CurrentAddEditLinkAction"),
            ("RemoteNewFileAction", "NewFileAction"), ("LocalNewFileAction", "NewFileAction"),
            ("LocalOpenDirAction", "RemoteOpenDirAction"), ("LocalRefreshAction", "RemoteRefreshAction"),
            ("LocalHomeDirAction", "RemoteHomeDirAction"),
            ("CurrentDeleteAction", "CurrentDeleteFocusedAction"),
            ("CurrentPropertiesAction", "CurrentPropertiesFocusedAction"),
            ("LocalCopyAction", "RemoteCopyAction"), ("LocalLocalCopyAction", "RemoteCopyAction"),
            ("LocalOtherCopyAction", "RemoteCopyAction"),
            ("LocalRenameAction2", "CurrentRenameAction"), ("LocalEditAction2", "CurrentEditAction"),
            ("LocalMoveAction", "RemoteMoveAction"), ("LocalLocalMoveAction", "RemoteMoveAction"),
            ("LocalOtherMoveAction", "RemoteMoveAction"),
            ("LocalCreateDirAction3", "CurrentCreateDirAction"),
            ("LocalDeleteAction2", "CurrentDeleteFocusedAction"),
            ("LocalPropertiesAction2", "CurrentPropertiesFocusedAction"),
            ("LocalCopyFocusedAction", "RemoteCopyAction"), ("LocalMoveFocusedAction", "RemoteMoveAction"),
            ("RemoteRenameAction2", "CurrentRenameAction"), ("RemoteEditAction2", "CurrentEditAction"),
            ("RemoteCreateDirAction3", "CurrentCreateDirAction"),
            ("RemoteDeleteAction2", "CurrentDeleteFocusedAction"),
            ("RemotePropertiesAction2", "CurrentPropertiesFocusedAction"),
            ("RemoteCopyFocusedAction", "RemoteCopyAction"), ("RemoteMoveFocusedAction", "RemoteMoveAction"),
        ]
        for (a, b) in clone { d[a] = d[b] }
        return d
    }()

    /// Mac で使えない・使うと困るもの (アプリ・編集・ウインドウの標準のキー)
    private static let reservedMac: Set<String> = ["⌘q", "⌘w", "⌘h", "⌘m", "⌘,", "⌥⌘h", "⌘a", "⌘c", "⌘v", "⌘x", "⌘z", "⇧⌘z", "⌘`"]

    /// Mac への置き換え (WinSCP の Ctrl+H ホーム → ⌘⇧H など)
    private static let macOverrides: [String: (String, NSEvent.ModifierFlags)] = [
        "LocalHomeDirAction": ("h", [.command, .shift]), "RemoteHomeDirAction": ("h", [.command, .shift]),
        "LocalBackAction": ("[", [.command]), "RemoteBackAction": ("[", [.command]),
        "LocalForwardAction": ("]", [.command]), "RemoteForwardAction": ("]", [.command]),
    ]

    /// Mac のキー (keyEquivalent と修飾キー)。Ctrl→⌘、Alt→⌥。修飾キーなしは F キーだけ
    func macKey(_ n: String) -> (String, NSEvent.ModifierFlags)? {
        if let o = WinSCPActions.macOverrides[n] { return o }
        // Ctrl+[ / Ctrl+] (パスをクリップボードへ) は ⌘[ ⌘] (戻る・進む) とぶつかるので付けない
        if n.hasSuffix("PathToClipboardAction2") { return nil }
        let sc = shortcut(n)
        guard sc != 0 else { return nil }
        let vk = sc & 0xFF
        var mods: NSEvent.ModifierFlags = []
        if sc & WinSCPActions.ctrlMask != 0 { mods.insert(.command) }
        if sc & WinSCPActions.altMask != 0 { mods.insert(.option) }
        if sc & WinSCPActions.shiftMask != 0 { mods.insert(.shift) }
        var k: String
        var isFKey = false
        switch vk {
        case 0x70...0x7B:
            k = String(Character(UnicodeScalar(NSF1FunctionKey + vk - 0x70)!)); isFKey = true
        case 0x41...0x5A: k = String(Character(UnicodeScalar(UInt8(vk + 32))))
        case 0x30...0x39: k = String(Character(UnicodeScalar(UInt8(vk))))
        case 0xDB: k = "["
        case 0xDD: k = "]"
        case 0xDC: k = "\\"
        case 0xBB: k = "="
        case 0xBD: k = "-"
        case 0xBF: k = "/"
        default: return nil   // Insert, Delete, ←→, Backspace, テンキーなどは一覧の表で処理する
        }
        if !isFKey && !mods.contains(.command) { return nil }
        var id = ""
        if mods.contains(.option) { id += "⌥" }
        if mods.contains(.shift) { id += "⇧" }
        if mods.contains(.command) { id += "⌘" }
        if WinSCPActions.reservedMac.contains(id + k) { return nil }
        return (k, mods)
    }
}

// MARK: - メニュー

/// ScpCommander.dfm の MenuToolbar からメニューを組み立てる
enum WinSCPMenu {
    /// アプリ全体で動くもの (コマンダーの窓がなくてもよい)
    static let appActions: Set<String> = [
        "PreferencesAction", "NewTabAction", "NewRemoteTabAction", "SiteManagerAction", "SavedSessionsAction2",
        "AboutAction", "HomepageAction", "ForumPageAction", "HistoryPageAction", "DonatePageAction",
        "TableOfContentsAction", "DownloadPageAction", "CheckForUpdatesAction",
    ]

    /// コマンダーで実装していないアクションのヒントに足す
    static let notSupported = "Mac 版では未対応です"

    /// メニューバーの WinSCP の部分 (ローカル / マーク / ファイル / コマンド / タブ / オプション / リモート / ヘルプ)
    static func topMenus() -> [NSMenuItem] {
        guard let bar = WinSCPActions.shared.commander?.find("MenuToolbar") else { return [] }
        return bar.children.compactMap { o -> NSMenuItem? in
            guard o.className == "TTBXSubmenuItem" else { return nil }
            let title: String
            switch o.name {
            case "LocalMenuButton": title = Translations.clean(Translations.str("LOCAL_MENU_CAPTION"))
            case "RemoteMenuButton": title = Translations.clean(Translations.str("REMOTE_MENU_CAPTION"))
            default: title = caption(o)
            }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            m.delegate = DynamicMenuDelegate.shared
            fill(m, o.children)
            top.submenu = m
            top.identifier = NSUserInterfaceItemIdentifier(o.name)
            return top
        }
    }

    /// ScpCommander.dfm の項目そのものの文言 (アクションの無いサブメニュー)
    static func caption(_ o: DFMObject) -> String {
        if let t = Translations.shared.get(section(o), o.path + ".Caption") { return Translations.clean(t) }
        return Translations.clean(o.str("Caption") ?? o.name)
    }

    /// 訳のセクション (その項目の .dfm)
    static func section(_ o: DFMObject) -> String {
        var x = o
        while let p = x.parent { x = p }
        return x.file ?? "ScpCommander.dfm"
    }

    static func fill(_ m: NSMenu, _ items: [DFMObject]) {
        for c in items {
            if c.className == "TTBXSeparatorItem" {
                // 先頭・連続の区切りは出さない (VCL も同じ)
                if let last = m.items.last, !last.isSeparatorItem { m.addItem(.separator()) }
                continue
            }
            m.addItem(item(c))
        }
        if m.items.last?.isSeparatorItem == true { m.removeItem(at: m.items.count - 1) }
    }

    static func actionName(_ o: DFMObject) -> String? {
        guard let a = o.str("Action") else { return nil }
        return a.components(separatedBy: ".").last
    }

    static func item(_ o: DFMObject) -> NSMenuItem {
        let acts = WinSCPActions.shared
        guard let a = actionName(o) else {
            // アクションの無いサブメニュー (移動 / 表示 / 並び替え など)
            let i = NSMenuItem(title: caption(o), action: nil, keyEquivalent: "")
            let sub = NSMenu(title: i.title)
            fill(sub, o.children)
            i.submenu = sub
            i.identifier = NSUserInterfaceItemIdentifier(o.name)
            if let h = Translations.shared.get(section(o), o.path + ".Hint") { i.toolTip = DFMForm.shortHint(h) }
            return i
        }
        let i = NSMenuItem(title: acts.caption(a), action: nil, keyEquivalent: "")
        i.representedObject = a
        i.identifier = NSUserInterfaceItemIdentifier(o.name)
        i.image = acts.image(a)
        i.toolTip = acts.hint(a).long
        if !o.children.isEmpty {
            // ドロップダウン付きの項目: Mac ではサブメニュー。親のショートカットは最初の子に
            let sub = NSMenu(title: i.title)
            fill(sub, o.children)
            if let first = sub.items.first(where: { !$0.isSeparatorItem }), first.keyEquivalent.isEmpty,
               let fa = first.representedObject as? String, acts.shortcut(fa) == 0, let k = acts.macKey(a) {
                first.keyEquivalent = k.0
                first.keyEquivalentModifierMask = k.1
            }
            i.submenu = sub
            return i
        }
        if a == "SavedSessionsAction2" {
            // 保存したセッション: Mac 版ではサイトマネージャーを開く項目だけ
            let sub = NSMenu(title: i.title)
            let sm = NSMenuItem(title: acts.caption("SiteManagerAction"), action: #selector(AppDelegate.winscpAppAction(_:)), keyEquivalent: "")
            sm.representedObject = "SiteManagerAction"
            sm.image = acts.image("SiteManagerAction")
            sub.addItem(sm)
            i.submenu = sub
            return i
        }
        if o.className == "TTBXSubmenuItem" && o.bool("DropdownCombo") != true {
            // 実行時に中身が入るサブメニュー (カスタム コマンド、開いているタブ など): Mac 版では空
            i.submenu = NSMenu(title: i.title)
            i.toolTip = notSupported
            return i
        }
        i.action = appActions.contains(a) ? #selector(AppDelegate.winscpAppAction(_:)) : #selector(CommanderWindowController.winscpAction(_:))
        if let k = acts.macKey(a) {
            i.keyEquivalent = k.0
            i.keyEquivalentModifierMask = k.1
        }
        return i
    }
}

/// メニューを開くとき、今のパネルに合わせて項目を入れ替える
/// (ファイル → コピー: リモートなら「ダウンロード」、ローカルなら「アップロード」。ScpCommander.cpp の UpdateControls)
final class DynamicMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = DynamicMenuDelegate()
    static let dynamicItems: Set<String> = ["CurrentCopyItem", "CurrentMoveItem", "CurrentCopyNonQueueItem", "CurrentCopyQueueItem"]

    /// 今のパネルの向きに合わせたアクションの名前
    static func adjust(_ a: String, remote: Bool) -> String {
        if remote, a.hasPrefix("Local") { return "Remote" + a.dropFirst(5) }
        if !remote, a.hasPrefix("Remote") { return "Local" + a.dropFirst(6) }
        return a
    }

    /// 項目の文言・絵・アクションを入れ替える
    static func update(_ item: NSMenuItem, remote: Bool) {
        guard let id = item.identifier?.rawValue, dynamicItems.contains(id), let a = item.representedObject as? String else { return }
        let b = adjust(a, remote: remote)
        guard b != a else { return }
        item.representedObject = b
        item.title = WinSCPActions.shared.caption(b)
        item.image = WinSCPActions.shared.image(b)
        item.toolTip = WinSCPActions.shared.hint(b).long
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let c = NSApp.keyWindow?.windowController as? CommanderWindowController ?? CommanderWindowController.all.last else { return }
        for i in menu.items { DynamicMenuDelegate.update(i, remote: c.activePanel.isRemote) }
    }
}

// MARK: - アプリ全体のアクション

extension AppDelegate {
    /// ウインドウ → 閉じる (⌘W)。performClose: を直接使うと AppKit が「すべて閉じる」を足すので
    @objc func closeKeyWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    @objc func winscpAppAction(_ sender: Any?) {
        guard let a = WinSCPAction.name(sender) else { return }
        func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
        switch a {
        case "PreferencesAction": showPreferences(sender)
        case "NewTabAction", "NewRemoteTabAction", "SiteManagerAction", "SavedSessionsAction2": newSession(sender)
        case "AboutAction": showAbout(sender)
        case "HomepageAction": open("https://github.com/satorunet/winscp_mac")
        // サポート (質問・不具合の報告) は WinSCP Mac の GitHub Discussions で受け付ける
        case "ForumPageAction": open(AppDelegate.supportURL)
        case "HistoryPageAction": open("https://github.com/\(Updater.repo)/releases")
        case "DonatePageAction": open("https://winscp.net/eng/donate.php")
        case "TableOfContentsAction": open("https://winscp.net/eng/docs/start")
        case "DownloadPageAction": open("https://github.com/\(Updater.repo)/releases")
        case "CheckForUpdatesAction": Updater.shared.checkNow(sender)
        default: break
        }
    }
}

/// メニュー項目・ボタンからアクションの名前を取り出す
enum WinSCPAction {
    static func name(_ sender: Any?) -> String? {
        if let m = sender as? NSMenuItem { return m.representedObject as? String }
        if let v = sender as? NSView { return v.identifier?.rawValue }
        if let t = sender as? NSToolbarItem { return t.itemIdentifier.rawValue.components(separatedBy: "#").first }
        return nil
    }
}

// MARK: - ツールバーのボタン

/// WinSCP のツールバーの 1 つのボタン (アクションの絵・文言・ヒント)。
/// ドロップダウン付き (DropdownCombo) は右端の ▾ でメニューを出す
final class ActionButton: NSButton {
    var actionName: String
    /// ▾ で出すメニュー (DropdownCombo の子)
    var dropdown: NSMenu?
    /// 押すとメニューだけ出す (アクションの無いサブメニュー: 「新規」など)
    var menuOnly = false
    var showsText = false

    init(action a: String, showsText: Bool) {
        actionName = a
        self.showsText = showsText
        super.init(frame: .zero)
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = true
        setButtonType(.momentaryPushIn)
        controlSize = .small
        font = .systemFont(ofSize: 11)
        target = nil
        self.action = #selector(CommanderWindowController.winscpAction(_:))
        refresh()
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// アクションが変わったとき (コピー: ダウンロード ↔ アップロード) に文言と絵を入れ直す
    func refresh(caption: String? = nil) {
        let acts = WinSCPActions.shared
        identifier = NSUserInterfaceItemIdentifier(actionName)
        if menuOnly { return }
        let img = acts.image(actionName)
        image = img
        var t = showsText || img == nil ? (caption ?? acts.caption(actionName)) : ""
        if t.hasSuffix("...") { t.removeLast(3) }
        if dropdown != nil { t += t.isEmpty ? "▾" : " ▾" }
        title = t
        imagePosition = t.isEmpty ? .imageOnly : (img == nil ? .noImage : .imageLeading)
        var tip = acts.hint(actionName).short
        if let k = acts.macKey(actionName) { tip += " (\(ActionButton.keyText(k.0, k.1)))" }
        toolTip = tip.isEmpty ? nil : tip
    }

    static func keyText(_ k: String, _ m: NSEvent.ModifierFlags) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        if let u = k.unicodeScalars.first, Int(u.value) >= NSF1FunctionKey, Int(u.value) <= NSF35FunctionKey {
            return s + "F\(Int(u.value) - NSF1FunctionKey + 1)"
        }
        return s + k.uppercased()
    }

    override func mouseDown(with event: NSEvent) {
        guard let m = dropdown, isEnabled || menuOnly else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        if menuOnly || p.x > bounds.width - 16 {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
            return
        }
        super.mouseDown(with: event)
    }
}

/// ScpCommander.dfm のツールバー (TTBXToolbar) を AppKit の横並びにする
enum ToolbarFactory {
    /// 1 本のツールバー。special は特別な項目 (パスの欄など) を差し替える
    static func band(_ tb: DFMObject, special: (DFMObject) -> NSView? = { _ in nil }) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 1
        row.alignment = .centerY
        for c in tb.children {
            if let v = special(c) { row.addArrangedSubview(v); continue }
            if let v = item(c) { row.addArrangedSubview(v) }
        }
        return row
    }

    static func separator() -> NSView {
        let s = NSBox()
        s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        let w = NSView()
        w.translatesAutoresizingMaskIntoConstraints = false
        w.addSubview(s)
        NSLayoutConstraint.activate([
            s.widthAnchor.constraint(equalToConstant: 1), s.heightAnchor.constraint(equalToConstant: 18),
            w.widthAnchor.constraint(equalToConstant: 7), w.heightAnchor.constraint(equalToConstant: 20),
            s.centerXAnchor.constraint(equalTo: w.centerXAnchor), s.centerYAnchor.constraint(equalTo: w.centerYAnchor),
        ])
        return w
    }

    static func item(_ c: DFMObject) -> NSView? {
        switch c.className {
        case "TTBXSeparatorItem":
            return separator()
        case "TTBXLabelItem":
            let l = NSTextField(labelWithString: WinSCPMenu.caption(c))
            l.font = .systemFont(ofSize: 12)
            return l
        case "TTBXItem", "TTBXSubmenuItem":
            let text = c.str("DisplayMode") == "nbdmImageAndText"
            if let a = WinSCPMenu.actionName(c) {
                let b = ActionButton(action: a, showsText: text)
                if !c.children.isEmpty {
                    let m = NSMenu()
                    WinSCPMenu.fill(m, c.children)
                    b.dropdown = m
                    b.refresh()
                }
                return b
            }
            // アクションの無いサブメニュー (「新規」「ディレクトリの表示を変更します」など): 押すとメニュー
            let b = ActionButton(action: c.name, showsText: text)
            let m = NSMenu()
            WinSCPMenu.fill(m, c.children)
            b.menuOnly = true
            b.dropdown = m
            b.action = nil
            // 絵は項目自身の ImageIndex、無ければ最初の子のアクションの絵
            b.image = c.int("ImageIndex").flatMap { WinSCPImages.explorer($0) }
                ?? c.children.compactMap(WinSCPMenu.actionName).first.flatMap { WinSCPActions.shared.image($0) }
            b.title = (text || b.image == nil ? WinSCPMenu.caption(c) + " " : "") + "▾"
            b.imagePosition = b.image == nil ? .noImage : .imageLeading
            b.toolTip = DFMForm.shortHint(Translations.shared.get(WinSCPMenu.section(c), c.path + ".Hint")
                                          ?? WinSCPMenu.caption(c))
            return b
        default:
            return nil
        }
    }
}
