import AppKit
import ScpCore
import UniformTypeIdentifiers

protocol FilePanelDelegate: AnyObject {
    func panelDidBecomeActive(_ p: FilePanel)
    /// ファイルを開く (ダブルクリック / Enter)
    func panel(_ p: FilePanel, open entry: FileEntry)
    /// ドロップされた (ローカルのファイル URL)
    func panel(_ p: FilePanel, dropLocal urls: [URL], into dir: String, move: Bool)
    /// ドロップされた (リモートの項目)
    func panel(_ p: FilePanel, dropRemote item: RemoteDrag, into dir: String, move: Bool)
    func panelContextMenu(_ p: FilePanel) -> NSMenu?
    /// Finder へドラッグしたリモートのファイルを書き出す (バックグラウンドで呼ばれる)
    func panel(_ p: FilePanel, writePromise entry: FileEntry, from dir: String, to url: URL) throws
}

/// パネル間ドラッグ中のリモート項目
final class RemoteDrag {
    static var current: RemoteDrag?
    weak var panel: FilePanel?
    let dir: String
    let entries: [FileEntry]
    init(panel: FilePanel, dir: String, entries: [FileEntry]) { self.panel = panel; self.dir = dir; self.entries = entries }
}

let remotePasteType = NSPasteboard.PasteboardType("net.satoru.winscpmac.remote")

/// 1 つのファイル一覧 (左のローカル / 右のリモート)
final class FilePanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSFilePromiseProviderDelegate {
    let isRemote: Bool
    weak var delegate: FilePanelDelegate?
    var session: Session?

    private(set) var path: String = "/"
    private(set) var entries: [FileEntry] = []       // 表示している順 (先頭は "..")
    private var all: [FileEntry] = []
    private var back: [String] = [], forward: [String] = []
    private var loading = false

    let table = PanelTableView()
    private let scroll = NSScrollView()
    /// パスの欄 (WinSCP の LocalPathComboBox / RemotePathComboBox: 上の階層の一覧から選べる)
    private let pathCombo = NSComboBox()
    private let header = NSView()
    /// ファイル一覧の上のパス (WinSCP の TPathLabel。アクティブなパネルは色が付く)
    private let pathLabel = NSTextField(labelWithString: "")
    private var titleText = ""
    private let status = NSTextField(labelWithString: "")
    /// ステータスバーの「n 非表示」 (押すと隠しファイルの表示を切り替える)
    private let hiddenButton = NSButton(title: "", target: nil, action: nil)
    private let statusBox = NSStackView()
    private let spinner = NSProgressIndicator()
    /// ツールバー (History / Navigation / Path / File / Selection) → 画面
    private var bands: [String: NSView] = [:]
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }()

    var active = false { didSet { updateActiveLook() } }
    /// "Local" / "Remote" (アクションの名前の頭)
    var side: String { isRemote ? "Remote" : "Local" }

    init(remote: Bool) {
        isRemote = remote
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 組み立て

    /// ScpCommander.dfm の LocalTopDock / RemoteTopDock の並び:
    ///   1 段目 … パス (欄・ディレクトリを開く・フィルタ)、履歴 (戻る・進む)、ナビゲーション (親・ルート・ホーム・更新 …)
    ///   2 段目 … ファイル (ダウンロード・編集・削除・名前変更・プロパティ・新規)、選択 (選択・選択解除・すべて選択)
    private func build() {
        header.wantsLayer = true
        pathCombo.delegate = self
        pathCombo.font = .systemFont(ofSize: 12)
        pathCombo.target = self
        pathCombo.action = #selector(pathEntered(_:))
        pathCombo.cell?.sendsActionOnEndEditing = false
        pathCombo.completes = false
        pathCombo.numberOfVisibleItems = 20
        pathCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathCombo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        pathCombo.controlSize = .small
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let dock = WinSCPActions.shared.commander?.find(side + "TopDock")
        func band(_ name: String) -> NSView {
            guard let tb = dock?.find(side + name + "Toolbar") else { return NSView() }
            let v = ToolbarFactory.band(tb) { [unowned self] c in
                if c.className == "TTBXComboBoxItem" { return self.pathCombo }
                return nil
            }
            if name == "Path" {
                v.setHuggingPriority(.defaultLow, for: .horizontal)
                v.addArrangedSubview(spinner)
            }
            bands[name] = v
            v.isHidden = !FilePanel.bandVisible(side + name)
            return v
        }
        // 幅が足りないときは、右のツールバーから隠れる (WinSCP のドックで帯が折り返すかわり)
        let row0 = NSStackView(views: [band("Path"), band("History"), band("Navigation")])
        let sel = band("Selection")
        let sep = ToolbarFactory.separator()
        let row1 = NSStackView(views: [band("File"), sep, sel, NSView()])
        for r in [row0, row1] { r.spacing = 4; r.alignment = .centerY }
        (row1.views.last)?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row1.setVisibilityPriority(.detachOnlyIfNecessary, for: sel)
        row1.setVisibilityPriority(.detachOnlyIfNecessary, for: sep)
        for r in [row0, row1] { r.setClippingResistancePriority(.defaultLow, for: .horizontal) }

        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.drawsBackground = true
        pathLabel.isBezeled = false
        let pathBox = NSStackView(views: [pathLabel])
        pathBox.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let headStack = NSStackView(views: [row0, row1])
        headStack.orientation = .vertical
        headStack.alignment = .leading
        headStack.spacing = 2
        headStack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        row0.trailingAnchor.constraint(equalTo: headStack.trailingAnchor, constant: -4).isActive = true
        row1.trailingAnchor.constraint(lessThanOrEqualTo: headStack.trailingAnchor, constant: -4).isActive = true
        header.addSubview(headStack)
        headStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headStack.topAnchor.constraint(equalTo: header.topAnchor),
            headStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        // 列 (WinSCP の既定: ローカル … 名前・サイズ・種類・更新日時 (属性は隠す)、
        //               リモート … 名前・サイズ・更新日時・パーミッション・所有者 (グループ・リンク先・種類は隠す))
        func col(_ id: String) -> String { Translations.str(id) }
        var cols: [(String, String, CGFloat, Bool)] = [
            ("name", col("Dirviewcolproperties_SDirViewNameCol"), 200, true),
            ("size", col("Dirviewcolproperties_SDirViewSizeCol"), 80, true),
        ]
        if isRemote {
            cols += [("type", col("Unixdirviewcolproperties_SUnixDirViewTypeCol"), 110, false),
                     ("mtime", col("Dirviewcolproperties_SDirViewChangedCol2"), 140, true),
                     ("rights", col("Unixdirviewcolproperties_SUnixDirViewRightsCol"), 85, true),
                     ("owner", col("Unixdirviewcolproperties_SUnixDirViewOwnerCol"), 70, true),
                     ("group", col("Unixdirviewcolproperties_SUnixDirViewGroupCol"), 60, false),
                     ("linktarget", col("Unixdirviewcolproperties_SUnixDirViewLinkTargetCol"), 150, false)]
        } else {
            cols += [("type", col("Dirviewcolproperties_SDirViewTypeCol"), 120, true),
                     ("mtime", col("Dirviewcolproperties_SDirViewChangedCol2"), 140, true),
                     ("attr", col("Dirviewcolproperties_SDirViewAttrCol"), 85, false)]
        }
        for (id, title, w, visible) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            c.minWidth = 30
            c.isHidden = !visible
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { c.headerCell.alignment = .right }
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(doubleClicked(_:))
        table.target = self
        table.panel = self
        table.autosaveName = isRemote ? "RemotePanelColumns2" : "LocalPanelColumns2"
        table.autosaveTableColumns = true
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL, remotePasteType])
        table.draggingDestinationFeedbackStyle = .regular
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        // パネルのステータスバー (WinSCP の LocalStatusBar / RemoteStatusBar: 選択の情報 | n 非表示 | n フィルタ済み)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hiddenButton.bezelStyle = .recessed
        hiddenButton.isBordered = false
        hiddenButton.font = .systemFont(ofSize: 11)
        hiddenButton.target = self
        hiddenButton.action = #selector(hiddenClicked(_:))
        hiddenButton.toolTip = Translations.shared.get("ScpCommander.dfm", "\(side)Panel.\(side)StatusBar.item1.Hint")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusBox.setViews([status, spacer, hiddenButton], in: .leading)
        statusBox.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 3, right: 8)
        statusBox.isHidden = !FilePanel.bandVisible(side + "StatusBar")

        let v = NSStackView(views: [header, pathLabel, scroll, statusBox])
        v.orientation = .vertical
        v.spacing = 0
        v.alignment = .leading
        addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        for x in [header, pathLabel, scroll, statusBox] {
            x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateActiveLook()
    }

    func setTitle(_ s: String) { titleText = s; pathLabel.toolTip = s }

    private func updateActiveLook() {
        // WinSCP: アクティブなパネルのパスはタイトルバーの色、そうでなければ灰色
        pathLabel.backgroundColor = active ? .controlAccentColor : .unemphasizedSelectedContentBackgroundColor
        pathLabel.textColor = active ? .white : .secondaryLabelColor
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // MARK: ツールバー・ステータスバーの表示 (オプション → ローカル パネル / リモート パネル)

    /// WinSCP の既定 (ToolbarsLayout): パネルのツールバーとステータスバーはすべて表示
    static func bandVisible(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "WinSCPBand." + key) as? Bool ?? true
    }

    func isBandVisible(_ name: String) -> Bool {
        name == "StatusBar" ? !statusBox.isHidden : !(bands[name]?.isHidden ?? true)
    }

    func setBand(_ name: String, visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "WinSCPBand." + side + name)
        if name == "StatusBar" { statusBox.isHidden = !visible } else { bands[name]?.isHidden = !visible }
    }

    /// パスの欄に移る (ドライブの変更 / パスの変更: Alt+F1 / Alt+F2)
    func focusPath() {
        window?.makeFirstResponder(pathCombo)
    }

    @objc func hiddenClicked(_ sender: Any?) {
        NSApp.sendAction(#selector(CommanderWindowController.toggleHidden(_:)), to: nil, from: self)
    }

    // MARK: 並び替え・列

    var sortKey: String { table.sortDescriptors.first?.key ?? "name" }
    var sortAscending: Bool { table.sortDescriptors.first?.ascending ?? true }

    /// 並び替えの列を選ぶ (同じ列ならそのまま)
    func sort(by key: String) {
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: key == sortKey ? sortAscending : true)]
    }
    func toggleSortAscending() {
        table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: !sortAscending)]
    }

    func column(_ id: String) -> NSTableColumn? { table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) }

    func autoSizeColumns() {
        for c in table.tableColumns where !c.isHidden {
            var w = (c.headerCell.cellSize.width) + 12
            for r in 0..<min(entries.count, 500) {
                if let v = tableView(table, viewFor: c, row: r) as? NSTableCellView, let t = v.textField {
                    w = max(w, ceil(t.cell?.cellSize.width ?? 0) + (c.identifier.rawValue == "name" ? 30 : 10))
                }
            }
            c.width = min(w, 600)
        }
    }

    private func updateNavButtons() {}

    // MARK: パス

    func join(_ name: String) -> String {
        isRemote ? RemotePath.join(path, name) : (path as NSString).appendingPathComponent(name)
    }
    var parentPath: String {
        isRemote ? RemotePath.parent(path) : (path as NSString).deletingLastPathComponent
    }
    var homePath: String { isRemote ? (session?.home ?? "/") : NSHomeDirectory() }

    /// ディレクトリを開く
    func navigate(_ p: String, record: Bool = true, select: String? = nil, completion: ((Bool) -> Void)? = nil) {
        var target = p
        if !isRemote { target = ((p as NSString).expandingTildeInPath as NSString).standardizingPath }
        else if !target.hasPrefix("/") { target = RemotePath.normalize(RemotePath.join(path, target)) }
        else { target = RemotePath.normalize(target) }
        load(target) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                if record && target != self.path { self.back.append(self.path); self.forward.removeAll() }
                self.path = target
                self.setPathText(target)
                self.updateNavButtons()
                if let s = select, let i = self.entries.firstIndex(where: { $0.name == s }) {
                    self.table.selectRowIndexes([i], byExtendingSelection: false)
                    self.table.scrollRowToVisible(i)
                } else if !self.entries.isEmpty {
                    self.table.selectRowIndexes([0], byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                }
            } else {
                self.setPathText(self.path)
            }
            completion?(ok)
        }
    }

    /// パスの欄と、一覧の上のパスを入れる。欄の選択肢は上の階層 (WinSCP のパスの欄と同じ)
    private func setPathText(_ p: String) {
        pathCombo.stringValue = p
        pathLabel.stringValue = " " + p
        var list: [String] = []
        var x = p
        while true {
            list.append(x)
            let up = isRemote ? RemotePath.parent(x) : (x as NSString).deletingLastPathComponent
            if up == x || up.isEmpty { break }
            x = up
        }
        pathCombo.removeAllItems()
        pathCombo.addItems(withObjectValues: list.reversed())
    }

    /// いまの場所をもう一度読む (選択はできるだけ残す)
    @objc func refresh(_ sender: Any?) { reload() }

    func reload(select names: [String]? = nil, completion: (() -> Void)? = nil) {
        let keep = names ?? selectedEntries.map(\.name)
        let firstRow = table.selectedRow
        load(path) { [weak self] ok in
            guard let self = self else { return }
            let idx = IndexSet(self.entries.indices.filter { keep.contains(self.entries[$0].name) })
            if !idx.isEmpty {
                self.table.selectRowIndexes(idx, byExtendingSelection: false)
            } else if !self.entries.isEmpty {
                self.table.selectRowIndexes([min(max(firstRow, 0), self.entries.count - 1)], byExtendingSelection: false)
            }
            completion?()
        }
    }

    private func load(_ p: String, completion: @escaping (Bool) -> Void) {
        if isRemote {
            guard let s = session else { completion(false); return }
            loading = true
            spinner.startAnimation(nil)
            s.run({ try $0.list(p) }) { [weak self] r in
                guard let self = self else { return }
                self.loading = false
                self.spinner.stopAnimation(nil)
                switch r {
                case .success(let list):
                    self.all = list
                    self.path = p
                    self.applyFilterAndSort()
                    completion(true)
                case .failure(let e):
                    Dialogs.error(e, title: "\(p) を開けません")
                    completion(false)
                }
            }
        } else {
            do {
                all = try FilePanel.listLocal(p)
                path = p
                applyFilterAndSort()
                completion(true)
            } catch {
                Dialogs.error(error, title: "\(p) を開けません")
                completion(false)
            }
        }
    }

    static func listLocal(_ p: String) throws -> [FileEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: p)
        return names.map { name -> FileEntry in
            let full = (p as NSString).appendingPathComponent(name)
            let a = (try? fm.attributesOfItem(atPath: full)) ?? [:]
            let type = a[.type] as? FileAttributeType
            let isLink = type == .typeSymbolicLink
            var isDir = type == .typeDirectory
            var size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            if isLink, let t = try? fm.attributesOfItem(atPath: (full as NSString).resolvingSymlinksInPath) {
                isDir = (t[.type] as? FileAttributeType) == .typeDirectory
                if !isDir { size = (t[.size] as? NSNumber)?.uint64Value ?? size }
            }
            // .app などのパッケージはファイルとして扱わない (WinSCP 同様フォルダとして開ける)
            return FileEntry(name: name, isDirectory: isDir, isSymlink: isLink, size: isDir ? 0 : size,
                             mtime: a[.modificationDate] as? Date,
                             permissions: (a[.posixPermissions] as? NSNumber).map { $0.uint32Value & 0o7777 },
                             owner: a[.ownerAccountName] as? String ?? "", group: a[.groupOwnerAccountName] as? String ?? "")
        }
    }

    func applyFilterAndSort() {
        var list = all
        if !Prefs.showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        let sd = table.sortDescriptors.first ?? NSSortDescriptor(key: "name", ascending: true)
        let asc = sd.ascending
        func cmpName(_ a: FileEntry, _ b: FileEntry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        list.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var r: ComparisonResult
            switch sd.key {
            case "size": r = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case "mtime":
                let x = a.mtime ?? .distantPast, y = b.mtime ?? .distantPast
                r = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case "type": r = typeName(a).localizedStandardCompare(typeName(b))
            case "rights", "attr": r = a.rightsString.compare(b.rightsString)
            case "owner": r = a.owner.compare(b.owner)
            case "group": r = a.group.compare(b.group)
            case "linktarget": r = (a.linkTarget ?? "").compare(b.linkTarget ?? "")
            case "ext":
                r = (a.name as NSString).pathExtension.localizedStandardCompare((b.name as NSString).pathExtension)
            default: r = a.name.localizedStandardCompare(b.name)
            }
            if r == .orderedSame { return cmpName(a, b) }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        let atRoot = isRemote ? path == "/" : path == "/"
        entries = (atRoot ? [] : [FileEntry(name: "..", isDirectory: true)]) + list
        table.reloadData()
        updateStatus()
    }

    func updateStatus() {
        let sel = selectedEntries
        let files = entries.filter { $0.name != ".." }
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        let selSize = sel.reduce(UInt64(0)) { $0 + $1.size }
        // WinSCP の FILE_INFO_FORMAT: 選択のサイズ / 全体のサイズ / 選択の数 / 全体の数
        let nf = FilePanel.numberFormatter
        status.stringValue = Translations.fmt("FILE_INFO_FORMAT", UI.size(selSize), UI.size(total),
                                              nf.string(from: NSNumber(value: sel.count)) ?? "", nf.string(from: NSNumber(value: files.count)) ?? "")
        let hidden = all.count - files.count
        hiddenButton.isHidden = hidden <= 0
        hiddenButton.title = Translations.fmt("FILE_INFO_HIDDEN2", nf.string(from: NSNumber(value: hidden)) ?? "")
    }

    // MARK: 選択

    /// 選ばれている項目 ("..") を除く
    var selectedEntries: [FileEntry] {
        table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }.filter { $0.name != ".." }
    }

    /// 選択が無ければカーソルの項目
    var focusedEntry: FileEntry? {
        let r = table.selectedRow
        return r >= 0 && r < entries.count ? entries[r] : nil
    }

    func selectAll() { table.selectRowIndexes(IndexSet(entries.indices.filter { entries[$0].name != ".." }), byExtendingSelection: false) }

    func select(names: [String]) {
        let idx = IndexSet(entries.indices.filter { names.contains(entries[$0].name) })
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if let f = idx.first { table.scrollRowToVisible(f) }
    }

    // MARK: 移動

    @objc func goUp(_ sender: Any?) {
        let cur = isRemote ? RemotePath.name(path) : (path as NSString).lastPathComponent
        if path != "/" { navigate(parentPath, select: cur) }
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// パスの欄の一覧から選んだら移る
    func comboBoxSelectionDidChange(_ notification: Notification) {
        let i = pathCombo.indexOfSelectedItem
        guard i >= 0, let p = pathCombo.itemObjectValue(at: i) as? String, p != path else { return }
        DispatchQueue.main.async { self.navigate(p); self.window?.makeFirstResponder(self.table) }
    }

    @objc func goRoot(_ sender: Any?) { navigate("/") }
    @objc func goHome(_ sender: Any?) { navigate(homePath) }
    @objc func goBack(_ sender: Any?) {
        guard let p = back.popLast() else { return }
        forward.append(path)
        navigate(p, record: false)
    }
    @objc func goForward(_ sender: Any?) {
        guard let p = forward.popLast() else { return }
        back.append(path)
        navigate(p, record: false)
    }
    @objc func pathEntered(_ sender: NSTextField) {
        navigate(sender.stringValue.trimmingCharacters(in: .whitespaces))
        window?.makeFirstResponder(table)
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openFocused()
    }

    func openFocused() {
        guard let e = focusedEntry else { return }
        if e.name == ".." { goUp(nil); return }
        if e.isDirectory { navigate(join(e.name)); return }
        delegate?.panel(self, open: e)
    }

    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0 && !entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    private static var iconCache: [String: NSImage] = [:]

    func icon(_ e: FileEntry) -> NSImage {
        if e.name == ".." { return NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: nil) ?? NSImage() }
        if e.isDirectory {
            if !isRemote && (e.name.hasSuffix(".app")) { return NSWorkspace.shared.icon(forFile: join(e.name)) }
            return NSImage(named: NSImage.folderName) ?? NSImage()
        }
        let ext = (e.name as NSString).pathExtension.lowercased()
        if let i = FilePanel.iconCache[ext] { return i }
        let i: NSImage
        if let t = UTType(filenameExtension: ext) { i = NSWorkspace.shared.icon(for: t) }
        else { i = NSWorkspace.shared.icon(for: .data) }
        FilePanel.iconCache[ext] = i
        return i
    }

    func typeName(_ e: FileEntry) -> String {
        if e.name == ".." { return "" }
        if e.isDirectory { return "フォルダ" }
        let ext = (e.name as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
        return ext.isEmpty ? "ファイル" : "\(ext.uppercased()) ファイル"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < entries.count else { return nil }
        let e = entries[row]
        let id = col.identifier
        let cell: NSTableCellView
        if let c = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = c
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.font = .systemFont(ofSize: 12)
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            cell.textField = t
            if id.rawValue == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv)
                cell.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                    t.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                ])
            } else {
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            if id.rawValue == "size" { t.alignment = .right }
            if ["rights", "attr", "size"].contains(id.rawValue) { t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        }
        let t = cell.textField!
        t.textColor = e.name.hasPrefix(".") && e.name != ".." ? .secondaryLabelColor : .labelColor
        switch id.rawValue {
        case "name":
            t.stringValue = e.name
            cell.imageView?.image = icon(e)
            cell.imageView?.alphaValue = e.name.hasPrefix(".") && e.name != ".." ? 0.5 : 1
            cell.toolTip = e.linkTarget.map { "\(e.name) → \($0)" }
        case "size": t.stringValue = e.isDirectory ? "" : FilePanel.sizeText(e.size)
        case "mtime": t.stringValue = e.mtime.map { UI.dateFormatter.string(from: $0) } ?? ""
        case "type": t.stringValue = typeName(e)
        case "rights": t.stringValue = e.name == ".." ? "" : (e.isSymlink ? "l" : (e.isDirectory ? "d" : "-")) + e.rightsString
        case "attr": t.stringValue = e.name == ".." || e.permissions == nil ? "" : e.rightsString
        case "owner": t.stringValue = e.owner
        case "group": t.stringValue = e.group
        case "linktarget": t.stringValue = e.linkTarget ?? ""
        default: t.stringValue = ""
        }
        return cell
    }

    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    static func sizeText(_ n: UInt64) -> String {
        if n < 1024 * 1024 { return (numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)") }
        return UI.size(n)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let keep = selectedEntries.map(\.name)
        applyFilterAndSort()
        select(names: keep)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier.rawValue == "name" ? entries[row].name : nil
    }

    // MARK: ドラッグ元

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let e = entries[row]
        if e.name == ".." { return nil }
        if !isRemote { return NSURL(fileURLWithPath: join(e.name)) }
        let type = e.isDirectory ? UTType.folder.identifier : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data).identifier
        let p = RemotePromise(fileType: type, delegate: self)
        p.userInfo = e
        p.dir = path
        return p
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        if isRemote {
            let list = rowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }.filter { $0.name != ".." }
            RemoteDrag.current = RemoteDrag(panel: self, dir: path, entries: list)
        }
    }

    // ファイルの約束 (Finder へのドラッグ)
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (p.userInfo as? FileEntry)?.name ?? "file"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let e = p.userInfo as? FileEntry, let d = delegate else { completionHandler(RemoteError("不明な項目")); return }
        do {
            try d.panel(self, writePromise: e, from: (p as? RemotePromise)?.dir ?? "", to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    // MARK: ドロップ先

    private func dropDir(row: Int, operation: NSTableView.DropOperation) -> String {
        if operation == .on, row >= 0, row < entries.count, entries[row].isDirectory {
            return entries[row].name == ".." ? parentPath : join(entries[row].name)
        }
        return path
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let pb = info.draggingPasteboard
        let fromSelf = (info.draggingSource as? NSTableView) === table
        if dropOperation == .on, !(row < entries.count && entries[row].isDirectory) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        if dropOperation == .above { tableView.setDropRow(-1, dropOperation: .on) }
        if fromSelf && (dropOperation == .above || !(row < entries.count && entries[row].isDirectory)) { return [] }
        let move = NSEvent.modifierFlags.contains(.shift)
        if isRemote {
            if pb.types?.contains(.fileURL) == true && !(pb.types?.contains(remotePasteType) ?? false) { return move ? .move : .copy }
            if fromSelf { return .move }
        } else {
            if pb.types?.contains(remotePasteType) == true, RemoteDrag.current != nil { return move ? .move : .copy }
            if fromSelf { return .move }
            if pb.types?.contains(.fileURL) == true { return move ? .move : .copy }
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let dir = dropDir(row: row, operation: dropOperation)
        let pb = info.draggingPasteboard
        let move = info.draggingSourceOperationMask == .move || NSEvent.modifierFlags.contains(.shift)
        if pb.types?.contains(remotePasteType) == true, let drag = RemoteDrag.current {
            delegate?.panel(self, dropRemote: drag, into: dir, move: move)
            RemoteDrag.current = nil
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            delegate?.panel(self, dropLocal: urls, into: dir, move: move)
            return true
        }
        return false
    }

    // MARK: その他

    func controlTextDidEndEditing(_ obj: Notification) {}

    func becameActive() { delegate?.panelDidBecomeActive(self) }

    var hasFocus: Bool { window?.firstResponder === table }
}

/// Finder にドラッグされたときに中身を後から作る
final class RemotePromise: NSFilePromiseProvider {
    var dir = ""
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [remotePasteType]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == remotePasteType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == remotePasteType { return (userInfo as? FileEntry)?.name ?? "" }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// キー操作を WinSCP に合わせた表
final class PanelTableView: NSTableView {
    weak var panel: FilePanel?

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { panel?.becameActive() }
        return r
    }

    override func mouseDown(with event: NSEvent) {
        panel?.becameActive()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        panel?.becameActive()
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return panel.flatMap { $0.delegate?.panelContextMenu($0) }
    }

    /// すべて選択 (⌘A) は ".." を除く
    override func selectAll(_ sender: Any?) {
        if let p = panel { p.selectAll() } else { super.selectAll(sender) }
    }

    override func keyDown(with event: NSEvent) {
        guard let p = panel else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // WinSCP のキーで、メニューに載せられないもの (修飾キーなし・テンキー)
        func action(_ name: String) {
            let i = NSMenuItem()
            i.representedObject = name
            NSApp.sendAction(#selector(CommanderWindowController.winscpAction(_:)), to: nil, from: i)
        }
        switch event.keyCode {
        case 69 where mods.isEmpty: action("SelectAction"); return          // テンキーの + : ファイルの選択
        case 78 where mods.isEmpty: action("UnselectAction"); return        // テンキーの - : 選択の解除
        case 67 where mods.isEmpty: action("InvertSelectionAction"); return // テンキーの * : 選択の切り替え
        case 47 where mods == [.command, .shift]:                           // ⌘⇧. : 隠しファイル (Finder と同じ)
            NSApp.sendAction(#selector(CommanderWindowController.toggleHidden(_:)), to: nil, from: self); return
        case 36, 76: // Return / Enter (Alt+Enter はプロパティ)
            if mods == .option { action("CurrentPropertiesFocusedAction"); return }
            if mods.isEmpty { p.openFocused(); return }
        case 51: // Backspace → 親ディレクトリ (⌘⌫ は削除)
            if mods.isEmpty { p.goUp(nil); return }
            if mods == .command { NSApp.sendAction(#selector(CommanderWindowController.deleteFiles(_:)), to: nil, from: self); return }
        case 117: // Delete (⌦)
            NSApp.sendAction(#selector(CommanderWindowController.deleteFiles(_:)), to: nil, from: self); return
        case 48: // Tab → もう一方のパネル
            if mods.isEmpty || mods == .shift {
                NSApp.sendAction(#selector(CommanderWindowController.switchPanel(_:)), to: nil, from: self); return
            }
        default: break
        }
        super.keyDown(with: event)
    }
}
