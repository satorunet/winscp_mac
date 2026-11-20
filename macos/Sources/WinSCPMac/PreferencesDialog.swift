import AppKit

/// WinSCP の「環境設定」(Preferences.dfm) をそのまま再現したダイアログ
/// 左のツリーで選んだページ (TTabSheet) を右に出す。OK で WinSCPConfig に保存、キャンセルで捨てる。
/// 設定は WinSCP.ini と同じキー (Configuration\Interface\ConfirmDeleting など) で読み書きする
/// (Preferences.cpp の LoadConfiguration / SaveConfiguration と同じ対応)
final class PreferencesDialog: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    static let unsupportedTip = "Mac 版では未対応です"

    let form: DFMForm
    private let tabs: NSTabView
    private let tree: TreeOutlineView
    private let cfg = WinSCPConfig.shared

    /// ツリーの項目 (SelectedIndex = TTabSheet の Tag)
    final class Node {
        let title: String
        let sheet: String
        var children: [Node] = []
        init(title: String, sheet: String) { self.title = title; self.sheet = sheet }
    }
    private var nodes: [Node] = []

    // MARK: 設定の読み書き

    /// 1 つの設定 (いくつかのキーをまとめて読み書きするものもある)
    private struct Binding {
        let keys: [String]
        /// 読んだ時の値 (キーが無ければ既定値)。保存時に変わったものだけ書く
        var loaded: [String]
        let save: () -> [String]
    }
    private var bindings: [Binding] = []

    /// Mac 版で使えない / まだ作っていない項目 (表示はするが無効)
    private var unsupported: Set<String> = []
    /// 操作に合わせて有効/無効を変える項目の、今の状態 (unsupported はいつも無効)
    private var enabledState: [String: Bool] = [:]
    /// コントロール → そのラベル (FocusControl と、WinSCP が一緒に切り替える単位のラベル)
    private var labelsFor: [String: [String]] = [:]

    private var editors: [EditorEntry] = []
    private var tables: [String: TableSource] = [:]
    private var searchResults: [(caption: String, sheet: String, view: NSView)] = []
    private var searchViews: [NSView] = []

    init?(page: String? = nil) {
        guard let f = DFMForm("Preferences.dfm"), let t = f.tabView("PageControl"),
              let tv = (f["NavigationTree"] as? NSScrollView)?.documentView as? TreeOutlineView else { return nil }
        form = f; tabs = t; tree = tv
        super.init()
        // WinSCP の HideComponentsPanel と同じく下の帯を隠して詰める
        f.hideComponentsPanel()
        prepareCaptions()
        buildTree()
        collectLabels()
        prepareTables()
        markUnsupported()
        load()
        wire()
        tree.dataSource = self
        tree.delegate = self
        tree.reloadData()
        tree.expandItem(nil, expandChildren: true)
        select(sheet: page ?? "PreferencesSheet")
        updateControls()
    }

    /// 環境設定を開く (OK なら保存して true)
    @discardableResult
    static func show(page: String? = nil, parent: NSWindow? = nil) -> Bool {
        guard let d = PreferencesDialog(page: page) else { return false }
        return d.run(parent: parent)
    }

    func run(parent: NSWindow? = nil) -> Bool {
        let r = form.runModal(parent: parent)
        guard r == "OKButton" else { return false }
        save()
        return true
    }

    /// TPreferencesDialog のコンストラクタで実行時に変えている文言など
    private func prepareCaptions() {
        let tr = Translations.shared
        if let s = tr.resource("SAVE_WORKSPACE_PASSWORDS") { form.button("AutoSaveWorkspacePasswordsCheck")?.title = Translations.clean(s) }
        // 文字コード: 既定 (Windows の ANSI。日本語版では Shift-JIS) と UTF-8
        form.popup("EditorEncodingCombo")?.addItems(withTitles: ["932  (ANSI/OEM - 日本語 Shift-JIS)", "UTF-8"])
        form.popup("PuttyRegistryStorageKeyEdit")?.addItems(withTitles: ["Software\\SimonTatham\\PuTTY\\Sessions", "Software\\9bis.com\\KiTTY\\Sessions"])
        form.combo("AutoWorkspaceCombo")?.addItems(withObjectValues: [tr.resource("NEW_WORKSPACE") ?? "マイ ワークスペース"])
        form.stepper("QueueTransferLimitEdit")?.maxValue = 9
        // ComboAutoSwitchInitialize
        form.popup("UpdatesBetaVersionsCombo")?.addItems(withTitles: ["AUTO_SWITCH_AUTO", "AUTO_SWITCH_OFF", "AUTO_SWITCH_ON"].map { tr.resource($0) ?? $0 })
        // 説明の行頭の "-" を "• " に (TPreferencesDialog::Bullet)
        for n in ["CommanderDescriptionLabel2", "ExplorerDescriptionLabel"] {
            guard let l = form.label(n) else { continue }
            var s = l.stringValue
            if s.hasPrefix("-") { s = "\u{2022} " + s.dropFirst() }
            l.stringValue = s.replacingOccurrences(of: "\n-", with: "\n\u{2022} ")
        }
    }

    // MARK: ツリー

    private func buildTree() {
        var bySheet: [Int: String] = [:]
        for s in tabs.tabViewItems {
            guard let n = s.identifier as? String, let o = form.object(n), let tag = o.int("Tag"), tag > 0 else { continue }
            bySheet[tag] = n
        }
        // ノードの文字はシートの題名 (訳) にする (PrepareNavigationTree と同じ)
        func make(_ d: TreeNodeData) -> Node? {
            guard let sheet = bySheet[d.selectedIndex], let o = form.object(sheet) else { return nil }
            let n = Node(title: form.text(o, "Caption") ?? d.text, sheet: sheet)
            n.children = d.children.compactMap(make)
            return n
        }
        nodes = tree.nodes.compactMap(make)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let l = NSTextField(labelWithString: (item as? Node)?.title ?? "")
        l.font = DFMForm.font
        l.lineBreakMode = .byTruncatingTail
        return l
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SelectionRowView() }
    // ツリーは畳まない (NavigationTreeCollapsing で禁止している)
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = tree.item(atRow: tree.selectedRow) as? Node else { return }
        tabs.selectTabViewItem(withIdentifier: n.sheet)
    }

    private func allNodes() -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) { out.append(n); n.children.forEach(walk) }
        nodes.forEach(walk)
        return out
    }

    /// そのページを出してツリーでも選ぶ
    func select(sheet: String) {
        tabs.selectTabViewItem(withIdentifier: sheet)
        if let n = allNodes().first(where: { $0.sheet == sheet }) {
            let row = tree.row(forItem: n)
            if row >= 0 { tree.selectRowIndexes([row], byExtendingSelection: false); tree.scrollRowToVisible(row) }
        } else {
            tree.deselectAll(nil)
        }
    }

    var currentSheet: String? { tabs.selectedTabViewItem?.identifier as? String }

    // MARK: 対応していない項目

    private func markUnsupported() {
        unsupported = [
            // 環境
            "DDTransferConfirmationCheck2", "ConfirmResumeCheck", "ConfirmRecyclingCheck",
            "ConfirmExitOnCompletionCheck", "ConfirmCommandSessionCheck", "SynchronizeSummaryCheck", "ContinueOnErrorCheck",
            "BeepOnFinishCheck", "BeepOnFinishAfterEdit", "BalloonNotificationsCheck", "FlashTaskbarCheck",
            // インターフェース (コマンダーだけ)
            "CommanderInterfaceButton2", "ExplorerInterfaceButton2",
            // ログ
            "EnableLoggingCheck", "LogProtocolCombo2", "LogFileNameEdit3", "LogFileNameHintText", "LogFileAppendButton",
            "LogFileOverwriteButton", "LogMaxSizeCheck", "LogMaxSizeCombo", "LogMaxSizeCountCheck", "LogMaxSizeCountEdit",
            "LogSensitiveCheck", "EnableActionsLoggingCheck", "ActionsLogFileNameEdit", "ActionsLogFileNameHintText",
            // パネル
            "DefaultDirIsHomeCheck", "PreservePanelStateCheck", "RenameWholeNameCheck", "FullRowSelectCheck",
            "NaturalOrderNumericalSortingCheck", "AlwaysSortDirectoriesByNameCheck", "FormatSizeBytesCombo", "PanelSearchCombo",
            "DoubleClickActionCombo", "CopyOnDoubleClickConfirmationCheck", "PanelFontCheck", "PanelFontButton", "PanelFontLabel",
            // ファイルの色
            "FileColorsView", "AddFileColorButton", "RemoveFileColorButton", "UpFileColorButton", "DownFileColorButton", "EditFileColorButton",
            // リモート / ローカル
            "ShowInaccesibleDirectoriesCheck", "AutoReadDirectoryAfterOpCheck", "RefreshRemotePanelCheck", "RefreshRemotePanelIntervalEdit",
            "PreserveLocalDirectoryCheck", "SystemContextMenuCheck", "DeleteToRecycleBinCheck",
            // コマンダー / エクスプローラー
            "NortonLikeModeCombo", "SwappedPanelsCheck", "TreeOnLeftCheck", "ExplorerKeyboardShortcutsCombo",
            "UseLocationProfilesCheck", "CompareByTimeCheck", "CompareBySizeCheck", "ShowFullAddressCheck",
            // 言語
            "LanguagesView", "LanguagesGetMoreButton",
            // エディタ
            "EditorCheckNotModifiedCheck",
            // 内蔵エディタ (Mac 版には内蔵エディタが無い)
            "EditorWordWrapCheck", "EditorTabSizeEdit", "EditorEncodingCombo", "EditorFontButton", "EditorFontColorButton",
            "EditorBackgroundColorButton", "EditorFontLabel", "EditorDisableSmoothScrollCheck", "EditorWarnLargeFileCheck", "EditorLargeFileSizeEdit",
            // 転送 (プリセット)
            "CopyParamListView", "AddCopyParamButton", "RemoveCopyParamButton", "UpCopyParamButton", "DownCopyParamButton",
            "EditCopyParamButton", "DuplicateCopyParamButton", "CopyParamAutoSelectNoticeCheck", "CopyParamLabel",
            // ドラッグ＆ドロップ (Windows のシェル拡張)
            "DDFakeFileEnabledButton", "DDFakeFileDisabledButton", "DDWarnLackOfTempSpaceCheck", "DDDrivesMemo", "DragExtStatusLabel",
            // バックグラウンド
            "QueueTransferLimitEdit", "QueueAutoPopupCheck", "QueueCheck", "QueueNoConfirmationCheck", "QueueParallelCheck",
            "EnableQueueByDefaultCheck", "QueueKeepDoneItemsForCombo", "ParallelTransferCheck", "ParallelTransferThresholdCombo",
            "QueueViewShowButton", "QueueViewHideWhenEmptyButton", "QueueViewHideButton",
            // 再開
            "ResumeOnButton", "ResumeSmartButton", "ResumeOffButton", "ResumeThresholdEdit", "SessionReopenAutoCheck",
            "SessionReopenAutoEdit", "SessionReopenAutoIdleCheck", "SessionReopenAutoIdleEdit", "SessionReopenAutoInactiveCheck",
            "SessionReopenAutoStallCheck", "SessionReopenAutoStallEdit", "SessionReopenTimeoutEdit",
            // ネットワーク
            "RetrieveExternalIpAddressButton", "CustomExternalIpAddressButton", "CustomExternalIpAddressEdit",
            "LocalPortNumberCheck", "LocalPortNumberMinEdit", "LocalPortNumberMaxEdit", "TryFtpWhenSshFailsCheck",
            // セキュリティ
            "UseMasterPasswordCheck", "SetMasterPasswordButton", "SessionRememberPasswordCheck", "AuthAgentCombo",
            "SshHostCAsView", "AddSshHostCAButton", "RemoveSshHostCAButton", "EditSshHostCAButton", "SshHostCAsFromPuTTYCheck", "ConfigureSshHostCAsButton",
            // ウィンドウ
            "PathInCaptionFullButton", "PathInCaptionShortButton", "PathInCaptionNoneButton", "MinimizeToTrayCheck",
            "ExternalSessionInExistingInstanceCheck", "KeepOpenWhenNoSessionCheck", "ShowTipsCheck", "ShowLoginWhenNoSessionCheck",
            "SessionTabCaptionTruncationCheck", "SessionSilentDisconnectCheck", "AutoSaveWorkspaceCheck", "AutoWorkspaceCombo",
            "AutoSaveWorkspacePasswordsCheck", "WorkspaceConnectAllCheck",
            // 統合 (Windows のシェル)
            "DesktopIconButton", "SendToHookButton", "RegisterAsUrlHandlersButton", "AddSearchPathButton", "ShellIconsText2",
            // アプリケーション (PuTTY のパス = ターミナルは使える)
            "PuttyPasswordCheck2", "AutoOpenInPuttyCheck", "TelnetForFtpInPuttyCheck", "PuttyPathHintText", "PuttyRegistryStorageKeyEdit",
            // コマンド
            "CustomCommandsView", "AddCommandButton", "RemoveCommandButton", "UpCommandButton", "DownCommandButton",
            "EditCommandButton", "ConfigureCommandButton",
            // 保存
            "RegistryStorageButton", "AutomaticIniFileStorageButton", "AutomaticIniFileStorageLabel", "CustomIniFileStorageButton", "CustomIniFileStorageEdit",
            "DDSystemTemporaryDirectoryButton", "DDCustomTemporaryDirectoryButton", "DDTemporaryDirectoryEdit",
            "TemporaryDirectoryCleanupCheck", "ConfirmTemporaryDirectoryCleanupCheck", "TemporaryDirectoryAppendSessionCheck",
            "TemporaryDirectoryAppendPathCheck", "TemporaryDirectoryDeterministicCheck", "RandomSeedFileEdit",
            // 更新
            "UpdatesPeriodCombo", "UpdatesShowOnStartup", "UpdatesAuthenticationEmailEdit", "UpdatesLink", "UpdatesProxyPortEdit",
            "UpdatesProxyHostEdit", "UpdatesProxyCheck", "UpdatesDirectCheck", "UpdatesAutoCheck", "UpdatesBetaVersionsCombo",
            "CollectUsageCheck", "UsageViewButton",
        ]
        for n in unsupported {
            guard let v = form[n] else { continue }
            setTip(v, PreferencesDialog.unsupportedTip)
            for l in labelsFor[n] ?? [] { if let lv = form[l] { setTip(lv, PreferencesDialog.unsupportedTip) } }
        }
    }

    private func setTip(_ v: NSView, _ tip: String) {
        v.toolTip = tip
        if v is NumberField || v is BrowseField { v.subviews.forEach { $0.toolTip = tip } }
        if let s = v as? NSScrollView { s.documentView?.toolTip = tip }
    }

    private func collectLabels() {
        for (name, o) in form.objects where ["TLabel", "TStaticText"].contains(o.className) {
            if let fc = o.str("FocusControl") { labelsFor[fc, default: []].append(name) }
        }
        // WinSCP の UpdateControls で一緒に切り替えている単位などのラベル
        let extra: [String: [String]] = [
            "BeepOnFinishAfterEdit": ["BeepOnFinishAfterText"],
            "LogFileNameEdit3": ["LogFileNameHintText"],
            "ActionsLogFileNameEdit": ["ActionsLogFileNameHintText"],
            "RefreshRemotePanelIntervalEdit": ["RefreshRemoteDirectoryUnitLabel"],
            "EditorLargeFileSizeEdit": ["EditorLargeFileSizeUnitLabel"],
            "LocalPortNumberMinEdit": ["LocalPortNumberRangeLabel"],
            "PanelFontCheck": ["PanelFontLabel"],
            "PuttyPasswordCheck2": ["PuttyPathHintText"],
        ]
        for (k, v) in extra { labelsFor[k, default: []].append(contentsOf: v) }
        // 一緒に切り替える単位のラベルが、別のコントロールにも付いている (DDFakeFileEnabledButton の DragExtStatusLabel など)
    }

    // MARK: 有効/無効

    private func setEnabled(_ name: String, _ on: Bool) {
        let e = on && !unsupported.contains(name)
        enabledState[name] = e
        if let v = form[name] { PreferencesDialog.enable(v, e) }
        for l in labelsFor[name] ?? [] {
            if let v = form[l] { PreferencesDialog.enable(v, e) }
        }
    }

    static func enable(_ v: NSView, _ e: Bool) {
        switch v {
        case let n as NumberField: n.isEnabled = e
        case let b as BrowseField: b.field.isEnabled = e; b.button.isEnabled = e
        case let s as NSScrollView:
            if let t = s.documentView as? NSTableView { t.isEnabled = e; t.alphaValue = e ? 1 : 0.6 }
            if let t = s.documentView as? NSTextView { t.isEditable = e; t.textColor = e ? .textColor : .disabledControlTextColor }
        case let l as NSTextField where !l.isEditable && !l.isBezeled:
            // ラベル (リンクは色を残す)
            if l.textColor == .linkColor || l.textColor == .disabledControlTextColor && l.tag == linkTag {
                l.textColor = e ? .linkColor : .disabledControlTextColor
                l.tag = linkTag
            } else {
                l.textColor = e ? .labelColor : .disabledControlTextColor
            }
        case let c as NSControl: c.isEnabled = e
        default: break
        }
    }
    private static let linkTag = 0x4C494E4B

    private func checked(_ n: String) -> Bool { form.button(n)?.state == .on }

    /// WinSCP の UpdateControls と同じ依存関係
    func updateControls() {
        // まず対応していないものは全部無効
        for n in unsupported { setEnabled(n, false) }

        setEnabled("DDTransferConfirmationCheck2", checked("ConfirmTransferringCheck"))
        setEnabled("BeepOnFinishAfterEdit", checked("BeepOnFinishCheck"))
        setEnabled("ResumeThresholdEdit", checked("ResumeSmartButton"))
        setEnabled("SessionReopenAutoEdit", checked("SessionReopenAutoCheck"))
        setEnabled("SessionReopenAutoIdleEdit", checked("SessionReopenAutoIdleCheck") || checked("SessionReopenAutoInactiveCheck"))
        setEnabled("SessionReopenAutoStallEdit", checked("SessionReopenAutoStallCheck"))
        setEnabled("SessionReopenTimeoutEdit", checked("SessionReopenAutoCheck") || checked("SessionReopenAutoStallCheck"))
        setEnabled("CopyOnDoubleClickConfirmationCheck",
                   form.popup("DoubleClickActionCombo")?.indexOfSelectedItem == 1 && checked("ConfirmTransferringCheck"))
        setEnabled("RefreshRemotePanelIntervalEdit", checked("RefreshRemotePanelCheck"))
        setEnabled("EditorLargeFileSizeEdit", checked("EditorWarnLargeFileCheck"))
        setEnabled("DDDrivesMemo", checked("DDFakeFileEnabledButton"))
        setEnabled("DDWarnLackOfTempSpaceCheck", checked("DDFakeFileDisabledButton"))
        setEnabled("DDTemporaryDirectoryEdit", checked("DDCustomTemporaryDirectoryButton"))
        setEnabled("ConfirmTemporaryDirectoryCleanupCheck", checked("TemporaryDirectoryCleanupCheck"))
        setEnabled("CustomIniFileStorageEdit", checked("CustomIniFileStorageButton"))

        // エディタ
        let sel = (tables["EditorListView3"]?.table.selectedRow) ?? -1
        setEnabled("EditEditorButton", sel >= 0)
        setEnabled("RemoveEditorButton", sel >= 0)
        setEnabled("UpEditorButton", sel > 0)
        setEnabled("DownEditorButton", sel >= 0 && sel < editors.count - 1)

        // 更新
        setEnabled("UsageViewButton", checked("CollectUsageCheck"))
        setEnabled("UpdatesProxyHostEdit", checked("UpdatesProxyCheck"))
        setEnabled("UpdatesProxyPortEdit", checked("UpdatesProxyCheck"))

        // アプリケーション (PuTTY = ターミナル)
        let anyPutty = !(form.combo("PuttyPathEdit")?.stringValue ?? "").isEmpty
        setEnabled("PuttyPasswordCheck2", anyPutty)
        setEnabled("AutoOpenInPuttyCheck", anyPutty)
        setEnabled("TelnetForFtpInPuttyCheck", anyPutty)
        setEnabled("PuttyRegistryStorageKeyEdit", anyPutty)

        // コマンド: 「設定」は拡張機能を選んだときだけ (「編集」と同じ場所)
        form.setVisible("EditCommandButton", true)
        form.setVisible("ConfigureCommandButton", false)

        // セキュリティ: PuTTY から読むときは「PuTTY で設定」だけ
        let caFromPutty = checked("SshHostCAsFromPuTTYCheck")
        for n in ["AddSshHostCAButton", "EditSshHostCAButton", "RemoveSshHostCAButton"] { form.setVisible(n, !caFromPutty) }
        form.setVisible("ConfigureSshHostCAsButton", caFromPutty)

        // ネットワーク
        setEnabled("CustomExternalIpAddressEdit", checked("CustomExternalIpAddressButton"))
        setEnabled("LocalPortNumberMinEdit", checked("LocalPortNumberCheck"))
        setEnabled("LocalPortNumberMaxEdit", checked("LocalPortNumberCheck"))

        // ウィンドウ
        setEnabled("AutoWorkspaceCombo", checked("AutoSaveWorkspaceCheck"))
        setEnabled("AutoSaveWorkspacePasswordsCheck", checked("AutoSaveWorkspaceCheck"))

        // ログ
        let logging = checked("EnableLoggingCheck")
        setEnabled("LogProtocolCombo2", logging)
        setEnabled("LogFileNameEdit3", logging)
        setEnabled("LogFileAppendButton", logging)
        setEnabled("LogFileOverwriteButton", logging)
        setEnabled("LogMaxSizeCheck", logging)
        setEnabled("LogMaxSizeCombo", logging && checked("LogMaxSizeCheck"))
        setEnabled("LogMaxSizeCountCheck", logging && checked("LogMaxSizeCheck"))
        setEnabled("LogMaxSizeCountEdit", logging && checked("LogMaxSizeCheck") && checked("LogMaxSizeCountCheck"))
        setEnabled("LogSensitiveCheck", logging)
        setEnabled("ActionsLogFileNameEdit", checked("EnableActionsLoggingCheck"))
        // デバッグのレベルのときだけ注意を出す
        form.setVisible("LogProtocolHintLabel", logging && (form.popup("LogProtocolCombo2")?.indexOfSelectedItem ?? 0) >= 2)
    }

    // MARK: 読み込み / 保存

    private func bind(_ keys: [String], _ defs: [String], load: ([String]) -> Void, save: @escaping () -> [String]) {
        let v = zip(keys, defs).map { cfg.values[$0.0] ?? $0.1 }
        load(v)
        bindings.append(Binding(keys: keys, loaded: v, save: save))
    }
    private func bind(_ key: String, _ def: String, load: (String) -> Void, save: @escaping () -> String) {
        bind([key], [def], load: { load($0[0]) }, save: { [save()] })
    }

    /// チェックボックス ↔ Bool のキー
    private func check(_ name: String, _ key: String, _ def: Bool, invert: Bool = false) {
        guard let b = form.button(name) else { return }
        bind(key, def ? "1" : "0", load: { b.state = (WinSCPConfig.isTrue($0) != invert) ? .on : .off },
             save: { (b.state == .on) != invert ? "1" : "0" })
    }

    /// ラジオボタンの組 ↔ 数値のキー (values[i] が names[i] の値)
    private func radios(_ names: [String], _ key: String, _ def: Int, values: [Int]? = nil) {
        let vals = values ?? Array(0..<names.count)
        bind(key, String(def), load: { v in
            let n = Int(v) ?? def
            let i = vals.firstIndex(of: n) ?? vals.firstIndex(of: def) ?? 0
            for (k, name) in names.enumerated() { form.button(name)?.state = k == i ? .on : .off }
        }, save: { [unowned self] in
            let i = names.firstIndex { self.checked($0) } ?? (vals.firstIndex(of: def) ?? 0)
            return String(vals[i])
        })
    }

    /// 選択肢 (csDropDownList) ↔ 数値のキー
    private func popup(_ name: String, _ key: String, _ def: Int, toIndex: @escaping (Int) -> Int = { $0 }, fromIndex: @escaping (Int) -> Int = { $0 }) {
        guard let p = form.popup(name) else { return }
        bind(key, String(def), load: { v in
            let i = toIndex(Int(v) ?? def)
            if i >= 0 && i < p.numberOfItems { p.selectItem(at: i) } else { p.selectItem(at: -1) }
        }, save: { String(fromIndex(p.indexOfSelectedItem)) })
    }

    /// 数字の欄 ↔ 数値のキー (scale で割って表示: ミリ秒 → 秒など)
    private func number(_ name: String, _ key: String, _ def: Int, scale: Int = 1) {
        guard let n = form.stepper(name) else { return }
        bind(key, String(def), load: { n.value = (Int($0) ?? def) / scale }, save: { String(n.value * scale) })
    }

    /// 文字の欄 ↔ 文字列のキー
    private func text(_ name: String, _ key: String, _ def: String = "") {
        guard let v = form[name] else { return }
        bind(key, def, load: { PreferencesDialog.setText(v, $0) }, save: { PreferencesDialog.getText(v) })
    }

    static func setText(_ v: NSView, _ s: String) {
        switch v {
        case let b as BrowseField: b.stringValue = s
        case let t as NSTextField: t.stringValue = s
        case let s2 as NSScrollView: (s2.documentView as? NSTextView)?.string = s
        default: break
        }
    }
    static func getText(_ v: NSView) -> String {
        switch v {
        case let b as BrowseField: return b.stringValue
        case let t as NSTextField: return t.stringValue
        case let s as NSScrollView: return (s.documentView as? NSTextView)?.string ?? ""
        default: return ""
        }
    }

    /// WinSCP の DateTime (日数) のキー ↔ 秒の欄
    private func secondsField(_ name: String, _ key: String, _ defSeconds: Double) {
        guard let n = form.stepper(name) else { return }
        bind(key, WinSCPConfig.dateTime(seconds: defSeconds), load: {
            n.value = Int(((WinSCPConfig.decodeDouble($0) ?? defSeconds / 86400) * 86400).rounded())
        }, save: { [unowned self] in
            // 値が同じなら読んだ文字のまま (16 進の表記の違いで書き直さない)
            let old = self.cfg.values[key].flatMap(WinSCPConfig.decodeDouble).map { Int(($0 * 86400).rounded()) }
            return old == n.value ? (self.cfg.values[key] ?? "") : WinSCPConfig.dateTime(seconds: Double(n.value))
        })
    }

    private func load() {
        let I = WinSCPKey.interface, CP = WinSCPKey.copyParam, E = WinSCPKey.editor, C = WinSCPKey.commander
        let L = WinSCPKey.logging, U = WinSCPKey.updates

        // 環境 (確認ダイアログ / 通知)
        check("ConfirmTransferringCheck", I + "ConfirmTransferring", true)
        if let b = form.button("DDTransferConfirmationCheck2") {
            // TAutoSwitch: asOn = 0 (オン), asOff = 1 (オフ), asAuto = 2 (グレー)
            bind(I + "DDTransferConfirmation2", "2", load: { v in
                let n = Int(v) ?? 2
                b.allowsMixedState = n == 2
                b.state = n == 0 ? .on : (n == 1 ? .off : .mixed)
            }, save: { b.state == .on ? "0" : (b.state == .off ? "1" : "2") })
        }
        check("ConfirmOverwritingCheck", I + "ConfirmOverwriting", true)
        check("ConfirmResumeCheck", I + "ConfirmResume", true)
        check("ConfirmDeletingCheck", I + "ConfirmDeleting", true)
        check("ConfirmRecyclingCheck", I + "ConfirmRecycling", true)
        check("ConfirmClosingSessionCheck2", I + "ConfirmClosingSession", true)
        check("ConfirmExitOnCompletionCheck", I + "ConfirmExitOnCompletion", true)
        check("ConfirmCommandSessionCheck", I + "ConfirmCommandSession", true)
        check("SynchronizeSummaryCheck", I + "SynchronizeSummary", true)
        check("ContinueOnErrorCheck", I + "ContinueOnError", false)
        check("BeepOnFinishCheck", I + "BeepOnFinish", false)
        secondsField("BeepOnFinishAfterEdit", I + "BeepOnFinishAfter", 30)
        check("BalloonNotificationsCheck", I + "BalloonNotifications", true)
        check("FlashTaskbarCheck", I + "FlashTaskbar", true)

        // ログ
        check("EnableLoggingCheck", L + "Logging", false)
        popup("LogProtocolCombo2", L + "LogProtocol", 0, toIndex: { $0 + 1 }, fromIndex: { $0 - 1 })
        text("LogFileNameEdit3", L + "LogFileName", "%TEMP%\\!S.log")
        radios(["LogFileAppendButton", "LogFileOverwriteButton"], L + "LogFileAppend", 1, values: [1, 0])
        if let cb = form.button("LogMaxSizeCheck"), let co = form.combo("LogMaxSizeCombo") {
            bind(L + "LogMaxSize", "0", load: { v in
                let n = Int64(v) ?? 0
                cb.state = n > 0 ? .on : .off
                co.stringValue = PreferencesDialog.sizeToStr(n > 0 ? n : 1024 * 1024)
            }, save: { cb.state == .on ? String(PreferencesDialog.strToSize(co.stringValue) ?? 0) : "0" })
        }
        if let cb = form.button("LogMaxSizeCountCheck"), let n = form.stepper("LogMaxSizeCountEdit") {
            bind(L + "LogMaxCount", "0", load: { v in
                let c = Int(v) ?? 0
                cb.state = c > 0 ? .on : .off
                n.value = c > 0 ? c : 5
            }, save: { cb.state == .on ? String(n.value) : "0" })
        }
        check("LogSensitiveCheck", L + "LogSensitive", false)
        check("EnableActionsLoggingCheck", L + "LogActions", false)
        text("ActionsLogFileNameEdit", L + "ActionsLogFileName", "%TEMP%\\!S.xml")

        // インターフェース
        radios(["CommanderInterfaceButton2", "ExplorerInterfaceButton2"], I + "Interface", 0)
        // ComboAutoSwitchLoad: 選択肢の番号 = 2 - 値 (自動 / ライト / ダーク)
        popup("ThemeCombo", I + "DarkTheme", 2, toIndex: { 2 - $0 }, fromIndex: { 2 - $0 })
        form.setVisible("InterfaceChangeLabel", false)

        // パネル
        check("ShowHiddenFilesCheck", I + "ShowHiddenFiles", false)
        check("DefaultDirIsHomeCheck", I + "DefaultDirIsHome", true)
        check("PreservePanelStateCheck", I + "PreservePanelState", true)
        check("RenameWholeNameCheck", I + "RenameWholeName", false)
        check("FullRowSelectCheck", I + "FullRowSelect", false)
        check("NaturalOrderNumericalSortingCheck", I + "NaturalOrderNumericalSorting", true)
        check("AlwaysSortDirectoriesByNameCheck", I + "AlwaysSortDirectoriesByName", false)
        popup("FormatSizeBytesCombo", I + "FormatSizeBytes", 1)
        // TIncrementalSearch: isOff = -1 (選択なし), isNameStartOnly, isName, isAll
        popup("PanelSearchCombo", I + "PanelSearch", 0)
        popup("DoubleClickActionCombo", I + "CopyOnDoubleClick", 2)
        check("CopyOnDoubleClickConfirmationCheck", I + "CopyOnDoubleClickConfirmation", false)
        if let b = form.button("PanelFontCheck") {
            bind([I + "PanelFontName", I + "PanelFontSize"], ["", "0"], load: { v in
                b.state = v[0].isEmpty ? .off : .on
                let f = NSFont.systemFont(ofSize: 0)
                let name = v[0].isEmpty ? (f.displayName ?? f.fontName) : v[0]
                let size = v[0].isEmpty ? Int(f.pointSize) : (Int(v[1]) ?? 9)
                self.form.label("PanelFontLabel")?.stringValue = PreferencesDialog.fontText(name, size)
            }, save: { [unowned self] in
                // フォントの選択は未対応なので、チェックを外したときだけ消す
                b.state == .on ? [self.cfg.values[I + "PanelFontName"] ?? "", self.cfg.values[I + "PanelFontSize"] ?? "0"] : ["", "0"]
            })
        }

        // コマンダー: TNortonLikeMode (nlOn = 0, nlOff = 1, nlKeyboard = 2) → 選択肢 (オン, キーボード, オフ)
        popup("NortonLikeModeCombo", C + "ExplorerStyleSelection", 2,
              toIndex: { [0: 0, 2: 1, 1: 2][$0] ?? 1 }, fromIndex: { [0: 0, 1: 2, 2: 1][$0] ?? 2 })
        check("SwappedPanelsCheck", C + "SwappedPanels", false)
        check("TreeOnLeftCheck", C + "TreeOnLeft", false)
        popup("ExplorerKeyboardShortcutsCombo", C + "ExplorerKeyboardShortcuts", 0, toIndex: { $0 != 0 ? 1 : 0 })
        check("UseLocationProfilesCheck", I + "UseLocationProfiles", false)
        check("CompareByTimeCheck", C + "CompareByTime", true)
        check("CompareBySizeCheck", C + "CompareBySize", false)

        // エクスプローラー
        check("ShowFullAddressCheck", WinSCPKey.explorer + "ShowFullAddress", true)

        // リモート / ローカル
        check("ShowInaccesibleDirectoriesCheck", I + "ShowInaccesibleDirectories", true)
        check("AutoReadDirectoryAfterOpCheck", I + "AutoReadDirectoryAfterOp", true)
        check("RefreshRemotePanelCheck", I + "RefreshRemotePanel", false)
        secondsField("RefreshRemotePanelIntervalEdit", I + "RefreshRemotePanelInterval", 60)
        check("PreserveLocalDirectoryCheck", C + "PreserveLocalDirectory", false)
        check("SystemContextMenuCheck", C + "SystemContextMenu", false)
        check("DeleteToRecycleBinCheck", I + "DeleteToRecycleBin", true)

        // ファイルの色 (色:マスク を CommaText で)
        bind(I + "FileColors", "", load: { v in
            self.tables["FileColorsView"]?.rows = PreferencesDialog.commaText(v).map { s in
                [s.firstIndex(of: ":").map { String(s[s.index(after: $0)...]) } ?? s]
            }
        }, save: { [unowned self] in self.cfg.values[I + "FileColors"] ?? "" })

        // エディタ
        editors = cfg.editorList
        reloadEditors()
        check("EditorCheckNotModifiedCheck", I + "EditorCheckNotModified", false)

        // 内蔵エディタ
        check("EditorWordWrapCheck", E + "WordWrap", false)
        number("EditorTabSizeEdit", E + "TabSize", 8)
        popup("EditorEncodingCombo", E + "Encoding", 65001, toIndex: { $0 == 65001 ? 1 : 0 }, fromIndex: { $0 == 1 ? 65001 : 0 })
        bind([E + "FontName2", E + "FontSize"], ["Consolas", "10"], load: { v in
            self.form.label("EditorFontLabel")?.stringValue = PreferencesDialog.fontText(v[0], Int(v[1]) ?? 10) + "\n\nABCD\n1234"
        }, save: { [unowned self] in [self.cfg.values[E + "FontName2"] ?? "Consolas", self.cfg.values[E + "FontSize"] ?? "10"] })
        check("EditorDisableSmoothScrollCheck", E + "DisableSmoothScroll", false)
        check("EditorWarnLargeFileCheck", E + "WarnOrLargeFileSize", true)
        number("EditorLargeFileSizeEdit", E + "LargeFileSize", 10 * 1024)

        // 転送 (プリセットの一覧の表示だけ)
        loadCopyParamList()
        check("CopyParamAutoSelectNoticeCheck", I + "CopyParamAutoSelectNotice", true)

        // ドラッグ＆ドロップ
        radios(["DDFakeFileEnabledButton", "DDFakeFileDisabledButton"], I + "DDFakeFile", 1, values: [1, 0])
        check("DDWarnLackOfTempSpaceCheck", I + "DDWarnLackOfTempSpace", true)
        if let m = form["DDDrivesMemo"] {
            bind(I + "DDDrives", "", load: { PreferencesDialog.setText(m, PreferencesDialog.commaText($0).joined(separator: "\n")) },
                 save: { PreferencesDialog.toCommaText(PreferencesDialog.getText(m).split(whereSeparator: \.isNewline).map(String.init)) })
        }
        if let l = form.label("DragExtStatusLabel") {
            l.stringValue = Translations.shared.resource("PREFERENCES_DRAGEXT_NOT_INSTALLED") ?? ""
            l.sizeToFit()
        }

        // バックグラウンド
        number("QueueTransferLimitEdit", I + "QueueTransfersLimit", 2)
        check("QueueAutoPopupCheck", I + "QueueAutoPopup", true)
        check("QueueCheck", CP + "Queue", false)
        check("QueueNoConfirmationCheck", CP + "QueueNoConfirmation", true)
        check("QueueParallelCheck", CP + "QueueParallel", true)
        check("EnableQueueByDefaultCheck", I + "EnableQueueByDefault", true)
        if let p = form.popup("QueueKeepDoneItemsForCombo") {
            bind([I + "QueueKeepDoneItems", I + "QueueKeepDoneItemsFor"], ["1", "15"], load: { v in
                let keep = WinSCPConfig.isTrue(v[0]), f = Int(v[1]) ?? 15
                p.selectItem(at: !keep ? 0 : (f < 0 ? 5 : (f <= 15 ? 1 : (f <= 60 ? 2 : (f <= 900 ? 3 : (f <= 3600 ? 4 : 5))))))
            }, save: {
                let i = p.indexOfSelectedItem
                return [i != 0 ? "1" : "0", String([0, 15, 60, 900, 3600][safe: i] ?? -1)]
            })
        }
        if let cb = form.button("ParallelTransferCheck"), let co = form.combo("ParallelTransferThresholdCombo") {
            // KB 単位。-1 = 既定 (オフ)
            bind(I + "ParallelTransferThreshold", "-1", load: { v in
                let n = Int64(v) ?? -1
                cb.state = n > 0 ? .on : .off
                co.stringValue = PreferencesDialog.sizeToStr(n > 0 ? n * 1024 : 100 * 1024 * 1024)
            }, save: {
                guard cb.state == .on, let s = PreferencesDialog.strToSize(co.stringValue) else { return "-1" }
                return String(min(s / 1024, Int64(Int32.max)))
            })
        }
        radios(["QueueViewShowButton", "QueueViewHideWhenEmptyButton", "QueueViewHideButton"], WinSCPKey.queueView + "Show", 1)

        // 保存 (Mac 版は UserDefaults に保存。どれも選ばない = WinSCP の stNul と同じ表示)
        for n in ["RegistryStorageButton", "AutomaticIniFileStorageButton", "AutomaticIniFileStorageLabel", "CustomIniFileStorageButton"] { form.button(n)?.state = .off }
        let plist = "~/Library/Preferences/\(Bundle.main.bundleIdentifier ?? "net.satoru.winscpmac").plist"
        form.label("AutomaticIniFileStorageLabel")?.stringValue = plist
        if let sys = form.button("DDSystemTemporaryDirectoryButton"), let cus = form.button("DDCustomTemporaryDirectoryButton"),
           let ed = form["DDTemporaryDirectoryEdit"] {
            bind(I + "DDTemporaryDirectory", "", load: { v in
                sys.state = v.isEmpty ? .on : .off
                cus.state = v.isEmpty ? .off : .on
                PreferencesDialog.setText(ed, v.isEmpty ? NSTemporaryDirectory() : v)
            }, save: { sys.state == .on ? "" : PreferencesDialog.getText(ed) })
        }
        check("TemporaryDirectoryCleanupCheck", I + "TemporaryDirectoryCleanup", true)
        check("ConfirmTemporaryDirectoryCleanupCheck", I + "ConfirmTemporaryDirectoryCleanup", true)
        check("TemporaryDirectoryAppendSessionCheck", I + "TemporaryDirectoryAppendSession", false)
        check("TemporaryDirectoryAppendPathCheck", I + "TemporaryDirectoryAppendPath", true)
        check("TemporaryDirectoryDeterministicCheck", I + "TemporaryDirectoryDeterministic", false)
        text("RandomSeedFileEdit", I + "RandomSeedFile", "%APPDATA%\\winscp.rnd")

        // 再開: TResumeSupport (rsOn, rsSmart, rsOff)、しきい値はバイト (表示は KB)
        radios(["ResumeOnButton", "ResumeSmartButton", "ResumeOffButton"], CP + "ResumeSupport", 1)
        number("ResumeThresholdEdit", CP + "ResumeThreshold", 100 * 1024, scale: 1024)
        if let cb = form.button("SessionReopenAutoCheck"), let n = form.stepper("SessionReopenAutoEdit") {
            bind(I + "SessionReopenAuto", "5000", load: { v in
                let ms = Int(v) ?? 5000
                cb.state = ms > 0 ? .on : .off
                n.value = ms > 0 ? ms / 1000 : 5
            }, save: { cb.state == .on ? String(n.value * 1000) : "0" })
        }
        if let cb = form.button("SessionReopenAutoIdleCheck"), let n = form.stepper("SessionReopenAutoIdleEdit") {
            bind([I + "SessionReopenAutoIdleOn", I + "SessionReopenAutoIdle"], ["1", "9000"], load: { v in
                let ms = Int(v[1]) ?? 9000
                cb.state = WinSCPConfig.isTrue(v[0]) && ms > 0 ? .on : .off
                n.value = (ms > 0 ? ms : 9000) / 1000
            }, save: { [cb.state == .on ? "1" : "0", String(n.value * 1000)] })
        }
        check("SessionReopenAutoInactiveCheck", I + "SessionReopenAutoInactive", false)
        if let cb = form.button("SessionReopenAutoStallCheck"), let n = form.stepper("SessionReopenAutoStallEdit") {
            bind(I + "SessionReopenAutoStall", "60000", load: { v in
                let ms = Int(v) ?? 60000
                cb.state = ms > 0 ? .on : .off
                n.value = ms > 0 ? ms / 1000 : 60
            }, save: { cb.state == .on ? String(n.value * 1000) : "0" })
        }
        number("SessionReopenTimeoutEdit", I + "SessionReopenTimeout", 0, scale: 1000)

        // 更新
        if let p = form.popup("UpdatesPeriodCombo") {
            bind(U + "Period", "0", load: { v in
                let d = Int(v) ?? 0
                p.selectItem(at: d <= 0 ? 0 : (d <= 1 ? 1 : (d <= 7 ? 2 : 3)))
            }, save: { String([0, 1, 7, 30][safe: p.indexOfSelectedItem] ?? 0) })
        }
        check("UpdatesShowOnStartup", U + "ShowOnStartup", true)
        text("UpdatesAuthenticationEmailEdit", U + "AuthenticationEmail")
        popup("UpdatesBetaVersionsCombo", U + "BetaVersions", 2, toIndex: { 2 - $0 }, fromIndex: { 2 - $0 })
        // TConnectionType: ctUndefined = -1, ctDirect, ctAuto, ctProxy
        radios(["UpdatesDirectCheck", "UpdatesAutoCheck", "UpdatesProxyCheck"], U + "ConnectionType", 0)
        text("UpdatesProxyHostEdit", U + "ProxyHost")
        number("UpdatesProxyPortEdit", U + "ProxyPort", 8080)
        check("CollectUsageCheck", I + "CollectUsage", false)

        // ウィンドウ: TPathInCaption (picShort, picFull, picNone)
        radios(["PathInCaptionShortButton", "PathInCaptionFullButton", "PathInCaptionNoneButton"], I + "PathInCaption", 0)
        check("MinimizeToTrayCheck", I + "MinimizeToTray", false)
        check("ExternalSessionInExistingInstanceCheck", I + "ExternalSessionInExistingInstance", true)
        check("ShowLoginWhenNoSessionCheck", I + "ShowLoginWhenNoSession", true)
        check("KeepOpenWhenNoSessionCheck", I + "KeepOpenWhenNoSession", true)
        check("SessionSilentDisconnectCheck", I + "SessionSilentDisconnect", false)
        check("SessionTabCaptionTruncationCheck", I + "SessionTabCaptionTruncation", true)
        check("ShowTipsCheck", I + "ShowTips", true)
        check("AutoSaveWorkspaceCheck", I + "AutoSaveWorkspace", false)
        let newWorkspace = Translations.shared.resource("NEW_WORKSPACE") ?? "マイ ワークスペース"
        text("AutoWorkspaceCombo", I + "AutoWorkspace", newWorkspace)
        check("AutoSaveWorkspacePasswordsCheck", I + "AutoSaveWorkspacePasswords", false)
        check("WorkspaceConnectAllCheck", I + "WorkspaceConnectAll", false)

        // セキュリティ
        check("UseMasterPasswordCheck", WinSCPKey.security + "UseMasterPassword", false)
        check("SessionRememberPasswordCheck", I + "QueueRememberPassword", true)
        popup("AuthAgentCombo", I + "AuthAgent", 0)
        check("SshHostCAsFromPuTTYCheck", I + "SshHostCAsFromPuTTY", false)

        // アプリケーション (PuTTY のパス = ターミナル)
        text("PuttyPathEdit", I + "PuttyPath", "")
        if let c = form.combo("PuttyPathEdit") {
            c.placeholderString = "Tera Term Mac (無ければターミナル)"
            c.toolTip = "Mac 版では「PuTTY で開く」に使うターミナルのアプリ (空なら Tera Term Mac、無ければターミナル)"
            c.addItems(withObjectValues: PreferencesDialog.terminalCandidates())
        }
        check("PuttyPasswordCheck2", I + "PuttyPassword", false)
        check("AutoOpenInPuttyCheck", I + "AutoOpenInPutty", false)
        check("TelnetForFtpInPuttyCheck", I + "TelnetForFtpInPutty", true)
        if let p = form.popup("PuttyRegistryStorageKeyEdit") {
            // 一覧に無いキー (自分で書いたもの) は選択なしで、保存時も書き換えない (SelectPuttyRegistryStorageKey と同じ)
            bind(I + "PuttyRegistryStorageKey", "Software\\SimonTatham\\PuTTY\\Sessions", load: { v in
                p.selectItem(withTitle: v)
                if p.titleOfSelectedItem != v { p.selectItem(at: -1) }
            }, save: { [unowned self] in p.titleOfSelectedItem ?? self.cfg.values[I + "PuttyRegistryStorageKey"] ?? "Software\\SimonTatham\\PuTTY\\Sessions" })
        }

        // ネットワーク
        if let r = form.button("RetrieveExternalIpAddressButton"), let c = form.button("CustomExternalIpAddressButton"),
           let ed = form.field("CustomExternalIpAddressEdit") {
            bind(I + "ExternalIpAddress", "", load: { v in
                r.state = v.isEmpty ? .on : .off
                c.state = v.isEmpty ? .off : .on
                ed.stringValue = v
            }, save: { c.state == .on ? ed.stringValue : "" })
        }
        if let cb = form.button("LocalPortNumberCheck"), let mn = form.stepper("LocalPortNumberMinEdit"), let mx = form.stepper("LocalPortNumberMaxEdit") {
            bind([I + "LocalPortNumberMin", I + "LocalPortNumberMax"], ["0", "0"], load: { v in
                let a = Int(v[0]) ?? 0, b = Int(v[1]) ?? 0
                cb.state = a > 0 || b > 0 ? .on : .off
                mn.value = a > 0 ? a : 49152
                mx.value = b >= mn.value ? b : Int(mx.maxValue)
            }, save: { cb.state == .on ? [String(mn.value), String(mx.value)] : ["0", "0"] })
        }
        check("TryFtpWhenSshFailsCheck", I + "TryFtpWhenSshFails", true)

        // 言語
        tables["LanguagesView"]?.rows = [["English"], ["日本語 - Japanese"]]
        tables["LanguagesView"]?.table.selectRowIndexes([1], byExtendingSelection: false)
        form.setVisible("LanguageChangeLabel", false)

        // コマンド
        loadCustomCommands()
    }

    /// 画面の値のうち、読んだときから変わったもの (キー → 値)
    func pendingChanges() -> [String: String?] {
        var changes: [String: String?] = [:]
        for b in bindings {
            let v = b.save()
            for (i, k) in b.keys.enumerated() where v[i] != b.loaded[i] { changes[k] = v[i] }
        }
        return changes
    }

    private func save() {
        let changes = pendingChanges()
        if editors != cfg.editorList { cfg.editorList = editors }
        cfg.update(changes)
        // すぐに反映する
        Prefs.applyTheme()
        for c in CommanderWindowController.all { c.local.applyFilterAndSort(); c.remote.applyFilterAndSort() }
    }

    // MARK: 一覧

    private func prepareTables() {
        for n in ["EditorListView3", "CustomCommandsView", "CopyParamListView", "SshHostCAsView", "LanguagesView", "FileColorsView"] {
            guard let t = (form[n] as? NSScrollView)?.documentView as? NSTableView else { continue }
            let s = TableSource(table: t)
            s.onSelect = { [weak self] in self?.updateControls() }
            tables[n] = s
        }
        tables["EditorListView3"]?.onDoubleClick = { [weak self] in self?.addEditEditor(edit: true) }
    }

    private func reloadEditors() {
        tables["EditorListView3"]?.rows = editors.map { e in
            [e.name, e.fileMask, e.editor == EditorEntry.externalEditor ? PreferencesDialog.yesNo(e.externalEditorText) : ""]
        }
    }

    private func loadCopyParamList() {
        let CP = WinSCPKey.copyParam
        var rows = [[Translations.clean(Translations.shared.resource("COPY_PARAM_DEFAULT") ?? "デフォルト"), ""]]
        let count = cfg.int(CP + "CopyParamList", -1)
        if count < 0 {
            for id in ["COPY_PARAM_PRESET_ASCII", "COPY_PARAM_PRESET_BINARY", "COPY_PARAM_NEWER_ONLY", "COPY_PARAM_PRESET_EXCLUDE_ALL_DIR"] {
                rows.append([Translations.clean(Translations.shared.resource(id) ?? id), PreferencesDialog.yesNo(false)])
            }
        } else {
            for i in 0..<count {
                rows.append([Translations.clean(cfg.string(CP + "\(i)\\Name")), PreferencesDialog.yesNo(cfg.bool(CP + "\(i)\\HasRule", false))])
            }
        }
        tables["CopyParamListView"]?.rows = rows
        tables["CopyParamListView"]?.table.selectRowIndexes([0], byExtendingSelection: false)
    }

    private func loadCustomCommands() {
        let R = WinSCPKey.root
        let local = Translations.shared.resource("CUSTOM_COMMAND_LOCAL") ?? "L"
        let remote = Translations.shared.resource("CUSTOM_COMMAND_REMOTE") ?? "R"
        var rows: [[String]] = []
        let cmds = cfg.values.filter { $0.key.hasPrefix(R + "CustomCommands\\") }
        if !cmds.isEmpty || cfg.bool(R + "CustomCommandsNone", false) {
            for (k, v) in cmds.sorted(by: { $0.key < $1.key }) {
                let name = String(k.dropFirst((R + "CustomCommands\\").count))
                let params = cfg.int(R + "CustomCommandsParams\\" + name, 0)
                rows.append([Translations.clean(name), v, params & 0x100 != 0 ? local : remote])
            }
        } else {
            // WinSCP の既定のカスタム コマンド (TWinConfiguration::DefaultLocalized)
            func s(_ id: String) -> String { Translations.clean(Translations.shared.resource(id) ?? id) }
            rows = [
                [s("CUSTOM_COMMAND_EXECUTE"), "\"./!\"", remote],
                [s("CUSTOM_COMMAND_TOUCH"), "touch \"!\"", remote],
                [s("CUSTOM_COMMAND_TAR"), "tar -cz  -f \"!?\(s("CUSTOM_COMMAND_TAR_ARCHIVE"))?archive.tgz!\" !&", remote],
                [s("CUSTOM_COMMAND_UNTAR"), "tar -xz --directory=\"!?\(s("CUSTOM_COMMAND_UNTAR_DIRECTORY"))?.!\" -f \"!\"", remote],
                [s("CUSTOM_COMMAND_GREP"), "grep \"!?\(s("CUSTOM_COMMAND_GREP_PATTERN"))?!\" !&", remote],
                [s("CUSTOM_COMMAND_PRINT"), "notepad.exe /p \"!\"", local],
            ]
        }
        tables["CustomCommandsView"]?.rows = rows
    }

    // MARK: エディタの一覧の操作

    private func addEditEditor(edit: Bool) {
        let t = tables["EditorListView3"]!.table
        let idx = t.selectedRow
        if edit && idx < 0 { return }
        guard var e = EditorPreferencesDialog.run(edit ? editors[idx] : EditorEntry(), edit: edit, parent: form.view.window) else { return }
        if !edit { e.fileMask = e.fileMask.isEmpty ? "*.*" : e.fileMask }
        var sel = idx
        if edit { editors[idx] = e } else if idx < 0 { editors.append(e); sel = editors.count - 1 } else { editors.insert(e, at: idx) }
        reloadEditors()
        t.selectRowIndexes([sel], byExtendingSelection: false)
        updateControls()
    }

    private func moveEditor(_ d: Int) {
        let t = tables["EditorListView3"]!.table
        let i = t.selectedRow, j = i + d
        guard i >= 0, j >= 0, j < editors.count else { return }
        editors.swapAt(i, j)
        reloadEditors()
        t.selectRowIndexes([j], byExtendingSelection: false)
        updateControls()
    }

    // MARK: 操作の割り当て

    private func wire() {
        // 有効/無効を変えるもの
        form.onChange([
            "ConfirmTransferringCheck", "BeepOnFinishCheck", "DoubleClickActionCombo", "RefreshRemotePanelCheck", "EditorWarnLargeFileCheck",
            "DDFakeFileEnabledButton", "DDFakeFileDisabledButton", "DDSystemTemporaryDirectoryButton", "DDCustomTemporaryDirectoryButton",
            "TemporaryDirectoryCleanupCheck", "CustomIniFileStorageButton", "ResumeOnButton", "ResumeSmartButton", "ResumeOffButton",
            "SessionReopenAutoCheck", "SessionReopenAutoIdleCheck", "SessionReopenAutoInactiveCheck", "SessionReopenAutoStallCheck",
            "CollectUsageCheck", "UpdatesProxyCheck", "UpdatesDirectCheck", "UpdatesAutoCheck",
            "RetrieveExternalIpAddressButton", "CustomExternalIpAddressButton", "LocalPortNumberCheck", "AutoSaveWorkspaceCheck",
            "EnableLoggingCheck", "LogMaxSizeCheck", "LogMaxSizeCountCheck", "EnableActionsLoggingCheck", "LogProtocolCombo2",
        ]) { [weak self] in self?.updateControls() }
        // 3 状態のチェックは、一度オン/オフを選んだら「自動」に戻さない (WinSCP と同じ)
        if let b = form.button("DDTransferConfirmationCheck2") {
            let t = ClosureTarget { b.allowsMixedState = false; if b.state == .mixed { b.state = .on } }
            b.target = t; b.action = #selector(ClosureTarget.fire)
            targets.append(t)
        }
        (form.combo("PuttyPathEdit"))?.delegate = self

        action("BackgroundConfirmationsLink") { [weak self] in self?.select(sheet: "QueueSheet") }
        action("AddEditorButton") { [weak self] in self?.addEditEditor(edit: false) }
        action("EditEditorButton") { [weak self] in self?.addEditEditor(edit: true) }
        action("UpEditorButton") { [weak self] in self?.moveEditor(-1) }
        action("DownEditorButton") { [weak self] in self?.moveEditor(1) }
        action("RemoveEditorButton") { [weak self] in
            guard let self = self, let t = self.tables["EditorListView3"]?.table, t.selectedRow >= 0 else { return }
            let i = t.selectedRow
            self.editors.remove(at: i)
            self.reloadEditors()
            if !self.editors.isEmpty { t.selectRowIndexes([min(i, self.editors.count - 1)], byExtendingSelection: false) }
            self.updateControls()
        }
        action("PuttyPathBrowseButton") { [weak self] in
            guard let self = self, let c = self.form.combo("PuttyPathEdit") else { return }
            let o = NSOpenPanel()
            o.title = Translations.shared.resource("PREFERENCES_SELECT_PUTTY2") ?? ""
            o.directoryURL = URL(fileURLWithPath: "/Applications")
            o.allowedFileTypes = ["app"]
            if o.runModal() == .OK, let u = o.url { c.stringValue = u.path; self.updateControls() }
        }
        action("HelpButton") { [weak self] in
            let kw = self?.currentSheet.flatMap { self?.form.object($0)?.str("HelpKeyword") } ?? "ui_preferences"
            NSWorkspace.shared.open(URL(string: "https://winscp.net/eng/docs/\(kw)")!)
        }
        // 検索
        if let s = form["SearchEdit"] as? BrowseField {
            s.field.delegate = self
            s.field.placeholderString = "検索"
            s.onBrowse = { [weak self] in s.stringValue = ""; self?.search("") }
            layoutSearch()
        }
        // リンク (TStaticText)
        for n in ["BackgroundConfirmationsLink", "UpdatesLink", "LogFileNameHintText", "ActionsLogFileNameHintText", "PuttyPathHintText"] {
            form.label(n)?.textColor = .linkColor
        }
    }
    private var targets: [AnyObject] = []

    /// ボタン / リンクのラベルを押したとき
    private func action(_ name: String, _ f: @escaping () -> Void) {
        guard let v = form[name] else { return }
        let t = ClosureTarget(f)
        targets.append(t)
        if let b = v as? NSButton {
            b.target = t; b.action = #selector(ClosureTarget.fire)
        } else {
            let g = NSClickGestureRecognizer(target: t, action: #selector(ClosureTarget.fire))
            v.addGestureRecognizer(g)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if let s = form["SearchEdit"] as? BrowseField, f === s.field { search(f.stringValue); return }
        updateControls()
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }

    // MARK: 検索 (SearchEditChangeEnter と同じく、文言を探して結果をリンクで並べる)

    private func layoutSearch() {
        guard let s = form["SearchEdit"] as? BrowseField else { return }
        // 空のときは ✕ を出さない (ButtonWidth = 0)
        let empty = s.stringValue.isEmpty
        s.button.isHidden = empty
        s.field.frame.size.width = empty ? s.bounds.width : max(10, s.bounds.width - 34)
    }

    private func search(_ q: String) {
        layoutSearch()
        let text = q.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if currentSheet == "SearchSheet" { select(sheet: (tree.item(atRow: max(0, tree.selectedRow)) as? Node)?.sheet ?? "PreferencesSheet") }
            return
        }
        var results: [(String, String, NSView)] = []
        func caption(_ v: NSView) -> [String] {
            switch v {
            case let p as NSPopUpButton: return p.itemTitles
            case let b as NSButton where b.bezelStyle != .rounded || b.title.count >= 4: return [b.title]
            case let l as NSTextField where !l.isEditable && !l.isBezeled: return [l.stringValue]
            case let g as GroupBoxView: return [g.title]
            default: return []
            }
        }
        func walk(_ v: NSView, _ sheet: String) {
            guard !v.isHidden else { return }
            for c in caption(v) where c.count >= 4 && c.range(of: text, options: [.caseInsensitive, .widthInsensitive]) != nil {
                results.append((c, sheet, v))
            }
            if v is NumberField || v is BrowseField { return }
            // 上から、左から
            let subs = v.subviews.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            subs.forEach { walk($0, sheet) }
        }
        for n in allNodes() { if let v = form[n.sheet] { walk(v, n.sheet) } }
        searchResults = results
        showSearchResults()
        tree.deselectAll(nil)
        tabs.selectTabViewItem(withIdentifier: "SearchSheet")
    }

    private func showSearchResults() {
        guard let g = form["SearchGroup"] else { return }
        searchViews.forEach { $0.removeFromSuperview() }
        searchViews = []
        var top: CGFloat = 22
        let left: CGFloat = 11, width = g.bounds.width - left - 8
        if searchResults.isEmpty {
            let l = NSTextField(labelWithString: Translations.shared.resource("SEARCH_NO_RESULTS") ?? "")
            l.font = DFMForm.font
            l.frame = NSRect(x: left, y: top, width: width, height: 17)
            g.addSubview(l)
            searchViews.append(l)
            return
        }
        for (i, r) in searchResults.enumerated() {
            // 文脈 (グループの題名 » ...)
            var ctx: [String] = []
            var p = r.view.superview
            while let x = p, x !== form[r.sheet] {
                if let gb = x as? GroupBoxView, !gb.title.isEmpty { ctx.insert(gb.title, at: 0) }
                p = x.superview
            }
            let context = ctx.isEmpty ? "\u{BB}" : ctx.joined(separator: " \u{BB} ") + " \u{BB}"
            let cl = NSTextField(labelWithString: context)
            cl.font = DFMForm.font
            cl.textColor = .secondaryLabelColor
            cl.frame = NSRect(x: left, y: top, width: width, height: 16)
            let ll = NSTextField(labelWithString: r.caption)
            ll.font = DFMForm.font
            ll.textColor = .linkColor
            ll.lineBreakMode = .byTruncatingTail
            ll.frame = NSRect(x: left, y: top + 16, width: width, height: 17)
            if ll.frame.maxY > g.bounds.height - 4 { break }
            let t = ClosureTarget { [weak self] in self?.openSearchResult(i) }
            targets.append(t)
            ll.addGestureRecognizer(NSClickGestureRecognizer(target: t, action: #selector(ClosureTarget.fire)))
            g.addSubview(cl); g.addSubview(ll)
            searchViews += [cl, ll]
            top += 16 + 17 + 8
        }
    }

    private func openSearchResult(_ i: Int) {
        guard i < searchResults.count else { return }
        let r = searchResults[i]
        if let s = form["SearchEdit"] as? BrowseField { s.stringValue = ""; layoutSearch() }
        select(sheet: r.sheet)
        form.view.window?.makeFirstResponder(r.view is NSTextField && !(r.view as! NSTextField).isEditable ? nil : r.view)
    }

    // MARK: 小物

    static func yesNo(_ b: Bool) -> String {
        Translations.shared.resource(b ? "YES_STR" : "NO_STR") ?? (b ? "はい" : "いいえ")
    }

    static func fontText(_ name: String, _ size: Int) -> String {
        let fmt = Translations.shared.resource("EDITOR_FONT_FMT") ?? "%s, %d pt"
        return fmt.replacingOccurrences(of: "%s", with: name).replacingOccurrences(of: "%d", with: String(size))
    }

    /// WinSCP の SizeToStr (1024 の倍数なら K / M / G)
    static func sizeToStr(_ size: Int64) -> String {
        if size <= 0 || size % 1024 != 0 { return String(size) }
        var s = size / 1024
        if s % 1024 != 0 { return "\(s)K" }
        s /= 1024
        if s % 1024 != 0 { return "\(s)M" }
        return "\(s / 1024)G"
    }
    static func strToSize(_ str: String) -> Int64? {
        var t = str.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasSuffix("B") { t.removeLast() }
        var mul: Int64 = 1
        let units: [String: Int64] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024]
        if let c = t.last, let m = units[String(c)] { mul = m; t.removeLast() }
        guard let n = Int64(t.trimmingCharacters(in: .whitespaces)) else { return nil }
        return n * mul
    }

    /// Delphi の TStrings.CommaText
    static func commaText(_ s: String) -> [String] {
        // 区切りは , と空白。" で囲んだ中は "" が " 1 つ
        var out: [String] = []
        let a = Array(s)
        var i = 0
        func skipSpaces() { while i < a.count && a[i].isWhitespace { i += 1 } }
        skipSpaces()
        while i < a.count {
            var cur = ""
            if a[i] == "\"" {
                i += 1
                while i < a.count {
                    if a[i] == "\"" {
                        if i + 1 < a.count && a[i + 1] == "\"" { cur.append("\""); i += 2; continue }
                        i += 1; break
                    }
                    cur.append(a[i]); i += 1
                }
            } else {
                while i < a.count && a[i] != "," && !a[i].isWhitespace { cur.append(a[i]); i += 1 }
            }
            out.append(cur)
            skipSpaces()
            if i < a.count && a[i] == "," { i += 1; skipSpaces() }
        }
        return out.filter { !$0.isEmpty }
    }
    static func toCommaText(_ a: [String]) -> String {
        a.map { s in s.contains(where: { $0 == "," || $0 == " " || $0 == "\"" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
            .joined(separator: ",")
    }

    /// ターミナルの候補 (入っているもの)
    static func terminalCandidates() -> [String] {
        var out: [String] = []
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.satoru.teramac") { out.append(u.path) }
        for p in ["/System/Applications/Utilities/Terminal.app", "/Applications/iTerm.app"] where FileManager.default.fileExists(atPath: p) {
            out.append(p)
        }
        return out
    }

    // MARK: 画面の確認用 (WINSCPMAC_RENDER と WINSCPMAC_PREFS_PAGES=GeneralSheet,WindowSheet で PNG に)

    static func renderForTest(dir: String) {
        guard let pages = ProcessInfo.processInfo.environment["WINSCPMAC_PREFS_PAGES"] else { return }
        let list = pages == "all" ? ["PreferencesSheet", "GeneralSheet", "WindowSheet", "CommanderSheet", "ExplorerSheet", "LanguagesSheet",
                                      "PanelsSheet", "FileColorsSheet", "PanelRemoteSheet", "PanelLocalSheet", "EditorSheet",
                                      "EditorInternalSheet", "CopyParamListSheet", "DragDropSheet", "QueueSheet", "TransferEnduranceSheet",
                                      "NetworkSheet", "SecuritySheet", "LogSheet", "IntegrationSheet", "IntegrationAppSheet",
                                      "CustomCommandsSheet", "StorageSheet", "UpdatesSheet"]
                                   : pages.split(separator: ",").map(String.init)
        for p in list {
            guard let d = PreferencesDialog(page: p) else { continue }
            if p == "SearchSheet", let s = d.form["SearchEdit"] as? BrowseField { s.stringValue = "確認"; d.search("確認") }
            let w = NSWindow(contentRect: d.form.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.title = d.form.caption
            w.contentView = d.form.view
            w.orderFront(nil)
            w.makeFirstResponder(d.tree)
            SelfTest.snap(w, "Preferences-" + p)
            // 何も触らなければ保存しても何も変わらないこと
            let ch = d.pendingChanges()
            SelfTest.log.append("  \(p): tree row \(d.tree.selectedRow), page \(d.currentSheet ?? "-"), changes \(ch.count) \(ch.keys.sorted())")
            if p == "PanelsSheet" {
                // 1 つ切り替えると、そのキーだけが変わること
                d.form.button("ShowHiddenFilesCheck")?.performClick(nil)
                SelfTest.log.append("  toggle ShowHiddenFiles → \(d.pendingChanges().map { "\($0.key)=\($0.value ?? "nil")" })")
            }
            w.orderOut(nil)
        }
    }
}

/// 選択の色を自分で塗る行 (HideSelection = False: フォーカスが無くても選択を見せる)
final class SelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let key = (window?.firstResponder as? NSView).map { $0 === superview || $0.isDescendant(of: superview ?? $0) } ?? false
        (key && window?.isKeyWindow == true ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        bounds.insetBy(dx: 2, dy: 0).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized && window?.isKeyWindow == true ? .emphasized : .normal
    }
}

/// 一覧 (TListView) の中身
final class TableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table: NSTableView
    var rows: [[String]] = [] { didSet { table.reloadData() } }
    var onSelect: (() -> Void)?
    var onDoubleClick: (() -> Void)? { didSet { table.target = self; table.doubleAction = #selector(doubleClicked(_:)) } }

    init(table: NSTableView) {
        self.table = table
        super.init()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.allowsEmptySelection = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let i = tableColumn.flatMap { tableView.tableColumns.firstIndex(of: $0) } ?? 0
        let l = NSTextField(labelWithString: i < rows[row].count ? rows[row][i] : "")
        l.font = DFMForm.font
        l.lineBreakMode = .byTruncatingTail
        return l
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?() }
    @objc func doubleClicked(_ sender: Any?) { if table.clickedRow >= 0 { onDoubleClick?() } }
}

/// エディタの設定 (EditorPreferences.dfm)
enum EditorPreferencesDialog {
    static func run(_ entry: EditorEntry, edit: Bool, parent: NSWindow?) -> EditorEntry? {
        guard let f = DFMForm("EditorPreferences.dfm") else { return nil }
        // 追加 / 編集のときは「このエディタを記憶する」を出さずに詰める (TEditorPreferencesDialog::Init)
        if let ok = f.object("OkButton")?.int("Top"), let rem = f.object("RememberCheck")?.int("Top") {
            f.setVisible("RememberCheck", false)
            f.view.setFrameSize(NSSize(width: f.view.frame.width, height: f.view.frame.height - CGFloat(ok - rem)))
        }
        let internalB = f.button("EditorInternalButton"), externalB = f.button("EditorExternalButton"), openB = f.button("EditorOpenButton")
        let path = f.combo("ExternalEditorEdit"), mask = f.combo("MaskEdit")
        internalB?.state = entry.editor == EditorEntry.internalEditor ? .on : .off
        externalB?.state = entry.editor == EditorEntry.externalEditor ? .on : .off
        openB?.state = entry.editor == EditorEntry.openEditor ? .on : .off
        path?.stringValue = entry.externalEditorPath
        path?.placeholderString = "/Applications/..."
        mask?.stringValue = entry.fileMask
        f.button("ExternalEditorTextCheck")?.state = entry.externalEditorText ? .on : .off
        f.button("SDIExternalEditorCheck")?.state = entry.sdiExternalEditor ? .on : .off
        // Mac 版では使えないもの
        for n in ["ExternalEditorTextCheck", "SDIExternalEditorCheck"] {
            f[n]?.toolTip = PreferencesDialog.unsupportedTip
        }
        internalB?.toolTip = "Mac 版では、ファイルの種類ごとの既定のアプリ (無ければテキストエディット) で開きます"

        func update() {
            let ext = externalB?.state == .on
            path?.isEnabled = ext
            f.button("ExternalEditorBrowseButton")?.isEnabled = ext
            f.button("ExternalEditorTextCheck")?.isEnabled = false
            f.button("SDIExternalEditorCheck")?.isEnabled = false
            f.button("OkButton")?.isEnabled = !ext || !(path?.stringValue.isEmpty ?? true)
        }
        f.onChange(["EditorInternalButton", "EditorExternalButton", "EditorOpenButton"], update)
        var keep: [AnyObject] = []
        func act(_ n: String, _ g: @escaping () -> Void) {
            guard let b = f.button(n) else { return }
            let t = ClosureTarget(g); keep.append(t)
            b.target = t; b.action = #selector(ClosureTarget.fire)
        }
        act("ExternalEditorBrowseButton") {
            let o = NSOpenPanel()
            o.title = Translations.shared.resource("PREFERENCES_SELECT_EXTERNAL_EDITOR") ?? ""
            o.directoryURL = URL(fileURLWithPath: "/Applications")
            o.allowedFileTypes = ["app"]
            if o.runModal() == .OK, let u = o.url { path?.stringValue = u.path; update() }
        }
        // システム標準のエディタ = テキストエディット
        act("DefaultButton") {
            externalB?.state = .on; internalB?.state = .off; openB?.state = .off
            path?.stringValue = "/System/Applications/TextEdit.app"
            update()
        }
        act("HelpButton") { NSWorkspace.shared.open(URL(string: "https://winscp.net/eng/docs/ui_editor_preferences")!) }
        let pathWatch = ClosureTarget { update() }; keep.append(pathWatch)
        path?.target = pathWatch; path?.action = #selector(ClosureTarget.fire)
        let obs = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: path, queue: nil) { _ in update() }
        defer { NotificationCenter.default.removeObserver(obs) }
        update()
        let title = Translations.shared.resource(edit ? "EDITOR_EDIT" : "EDITOR_ADD")
        guard f.runModal(title: title, parent: parent) == "OkButton" else { return nil }
        _ = keep
        var e = entry
        e.editor = externalB?.state == .on ? EditorEntry.externalEditor : (openB?.state == .on ? EditorEntry.openEditor : EditorEntry.internalEditor)
        e.externalEditorPath = path?.stringValue ?? ""
        e.fileMask = mask?.stringValue ?? "*.*"
        return e
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
