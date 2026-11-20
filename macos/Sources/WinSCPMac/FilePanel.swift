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
final class FilePanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSFilePromiseProviderDelegate {
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
    private let pathField = NSTextField()
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var backButton: NSButton!, forwardButton: NSButton!
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }()

    var active = false { didSet { updateActiveLook() } }

    init(remote: Bool) {
        isRemote = remote
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 組み立て

    private func build() {
        header.wantsLayer = true
        titleLabel.font = .boldSystemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        pathField.delegate = self
        pathField.font = .systemFont(ofSize: 12)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.target = self
        pathField.action = #selector(pathEntered(_:))
        pathField.cell?.sendsActionOnEndEditing = false
        backButton = UI.iconButton("chevron.left", "戻る", self, #selector(goBack(_:)))
        forwardButton = UI.iconButton("chevron.right", "進む", self, #selector(goForward(_:)))
        let up = UI.iconButton("arrow.up", "親ディレクトリ (Backspace)", self, #selector(goUp(_:)))
        let root = UI.iconButton("externaldrive", "ルートディレクトリ", self, #selector(goRoot(_:)))
        let home = UI.iconButton("house", "ホームディレクトリ", self, #selector(goHome(_:)))
        let refresh = UI.iconButton("arrow.clockwise", "更新 (⌘R)", self, #selector(refresh(_:)))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let nav = NSStackView(views: [backButton, forwardButton, up, root, home, refresh, pathField, spinner])
        nav.spacing = 4
        let top = NSStackView(views: [titleLabel])
        top.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let headStack = NSStackView(views: [top, nav])
        headStack.orientation = .vertical
        headStack.alignment = .leading
        headStack.spacing = 4
        headStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        nav.leadingAnchor.constraint(equalTo: headStack.leadingAnchor, constant: 4).isActive = true
        nav.trailingAnchor.constraint(equalTo: headStack.trailingAnchor, constant: -4).isActive = true
        header.addSubview(headStack)
        headStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headStack.topAnchor.constraint(equalTo: header.topAnchor),
            headStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        // 列
        var cols: [(String, String, CGFloat)] = [("name", "名前", 220), ("size", "サイズ", 80)]
        if isRemote {
            cols += [("mtime", "更新日時", 140), ("rights", "パーミッション", 90), ("owner", "所有者", 80)]
        } else {
            cols += [("type", "種類", 110), ("mtime", "更新日時", 140)]
        }
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            c.minWidth = 40
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
        table.autosaveName = isRemote ? "RemotePanelColumns" : "LocalPanelColumns"
        table.autosaveTableColumns = true
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL, remotePasteType])
        table.draggingDestinationFeedbackStyle = .regular
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let statusBox = NSStackView(views: [status])
        statusBox.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 3, right: 8)

        let v = NSStackView(views: [header, scroll, statusBox])
        v.orientation = .vertical
        v.spacing = 0
        v.alignment = .leading
        addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        for x in [header, scroll, statusBox] {
            x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateActiveLook()
        updateNavButtons()
    }

    func setTitle(_ s: String) { titleLabel.stringValue = s }

    private func updateActiveLook() {
        header.layer?.backgroundColor = (active ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.windowBackgroundColor).cgColor
        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
    }

    private func updateNavButtons() {
        backButton.isEnabled = !back.isEmpty
        forwardButton.isEnabled = !forward.isEmpty
    }

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
                self.pathField.stringValue = target
                self.updateNavButtons()
                if let s = select, let i = self.entries.firstIndex(where: { $0.name == s }) {
                    self.table.selectRowIndexes([i], byExtendingSelection: false)
                    self.table.scrollRowToVisible(i)
                } else if !self.entries.isEmpty {
                    self.table.selectRowIndexes([0], byExtendingSelection: false)
                    self.table.scrollRowToVisible(0)
                }
            } else {
                self.pathField.stringValue = self.path
            }
            completion?(ok)
        }
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
            case "rights": r = a.rightsString.compare(b.rightsString)
            case "owner": r = a.owner.compare(b.owner)
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
        status.stringValue = "\(UI.size(selSize)) / \(UI.size(total))、 \(sel.count) / \(files.count) 項目"
            + (Prefs.showHidden ? "" : (all.count > files.count ? "、 隠しファイル \(all.count - files.count)" : ""))
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
            if id.rawValue == "rights" || id.rawValue == "size" { t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
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
        case "owner": t.stringValue = e.owner
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

    override func keyDown(with event: NSEvent) {
        guard let p = panel else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76: // Return / Enter
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
