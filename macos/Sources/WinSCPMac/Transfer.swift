import AppKit
import ScpCore

/// 進行状況のシート (WinSCP の Progress.dfm: アニメーション・ファイル・対象・全体のバー・時間・速度・ファイルのバー・
/// キャンセル / 最小化 / 終了時 / 速度)。値はバックグラウンドから入れ、0.1 秒ごとに画面へ写す
final class ProgressSheet: NSObject {
    /// 操作の種類 (WinSCP の foCopy / foMove / foDelete と、転送の向き)
    enum Kind {
        case upload(move: Bool)
        case download(move: Bool)
        case delete
        var isTransfer: Bool { if case .delete = self { return false }; return true }
    }

    let window: NSWindow
    let kind: Kind
    private let form: DFMForm?
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var timer: Timer?
    private let lock = NSLock()
    private var _cancelled = false
    private var started = Date()
    private var cancelTarget: ClosureTarget?
    private var minimizeTarget: ClosureTarget?

    // バックグラウンドから更新する値
    private var curFile = "", curTarget = ""
    private var fileDone: UInt64 = 0, fileSize: UInt64 = 0
    private var totalDone: UInt64 = 0, totalSize: UInt64 = 0
    private var countDone = 0, countTotal = 0
    private var indeterminate = true

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(kind: Kind) {
        self.kind = kind
        form = DFMForm("Progress.dfm")
        let size = form?.view.frame.size ?? NSSize(width: 398, height: 294)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        guard let f = form else { return }
        // 下の部品の欄は使わない (Progress.cpp の HideComponentsPanel: 欄の高さを 0 にして、その分だけ縮める)
        f.setVisible("ComponentsPanel", false)
        f.view.autoresizesSubviews = false
        f.view.setFrameSize(NSSize(width: f.view.frame.width, height: f.view.frame.height - CGFloat(f.object("ComponentsPanel")?.int("Height") ?? 110)))
        f.view.autoresizesSubviews = true
        if !kind.isTransfer {
            // 転送でなければ 対象 と 時間・速度 の欄は出さない (下のボタンはその分上へ)
            f.setVisible("TransferPanel", false)
            f.setVisible("TargetLabel", false)
            f.setVisible("TargetPathLabel", false)
            f.view.setFrameSize(NSSize(width: f.view.frame.width, height: f.view.frame.height - CGFloat(f.object("TransferPanel")?.int("Height") ?? 64)))
        }
        // 文言 (PROGRESS_FILE_LABEL、キャンセル)
        if let l = f.label("PathLabel") { l.stringValue = Translations.str("PROGRESS_FILE_LABEL"); l.sizeToFit() }
        if let c = f.button("CancelItem") {
            c.title = Dialogs.vcl("Cancel")
            let t = ClosureTarget { [weak self] in self?.cancel(nil) }
            c.target = t; c.action = #selector(ClosureTarget.fire)
            cancelTarget = t
        }
        if let m = f.button("MinimizeItem") {
            let t = ClosureTarget { [weak self] in self?.window.sheetParent?.miniaturize(nil) }
            m.target = t; m.action = #selector(ClosureTarget.fire)
            minimizeTarget = t
        }
        // スキップ・バックグラウンドへ: WinSCP でも、この場合は出さない
        f.setVisible("SkipItem", false)
        f.setVisible("MoveToQueueItem", false)
        // 終了時の動作・速度制限: Mac 版では未対応
        disableUnsupported(f.button("CycleOnceDoneItem"))
        if let s = f.combo("SpeedComboBoxItem") {
            s.stringValue = Translations.str("SPEED_UNLIMITED")
            s.isHidden = !kind.isTransfer
            disableUnsupported(s)
        }
        for n in ["FileLabel", "TargetPathLabel"] { f.label(n)?.lineBreakMode = .byTruncatingMiddle }
        // アニメーション (CopyRemote / CopyLocal / MoveRemote / MoveLocal / Delete)
        let anim: String
        switch kind {
        case .upload(let move): anim = move ? "MoveLocal" : "CopyLocal"
        case .download(let move): anim = move ? "MoveRemote" : "CopyRemote"
        case .delete: anim = "Delete"
        }
        frames = WinSCPImages.animation(anim)
        (f["AnimationPaintBox"] as? NSImageView)?.image = frames.first
        (f["AnimationPaintBox"] as? NSImageView)?.imageScaling = .scaleNone
        f.setVisible("StartTimeLabelLabel", true)
        f.setVisible("StartTimeLabel", true)
        f.setVisible("TimeLeftLabelLabel", false)
        f.setVisible("TimeLeftLabel", false)
        f.label("StartTimeLabel")?.stringValue = ProgressSheet.timeFormatter.string(from: Date())
        for b in ["OperationProgress", "FileProgress"] { (f[b] as? NSProgressIndicator)?.maxValue = 100 }
        // ボタンの列は中身の幅に合わせる (Progress.cpp の SizeToolbar)
        if let tb = f["Toolbar"] {
            tb.layoutSubtreeIfNeeded()
            let w = ceil(tb.fittingSize.width)
            for n in ["Toolbar", "Dock", "ToolbarPanel"] { f[n]?.frame.size.width = w }
        }
        window.setContentSize(f.view.frame.size)
        window.contentView = f.view
    }

    /// 進行中の題名: "37% アップロード中" (Progress.cpp の ProgressStr)
    private var operationName: String {
        switch kind {
        case .upload: return Translations.str("PROGRESS_UPLOAD")
        case .download: return Translations.str("PROGRESS_DOWNLOAD")
        case .delete: return Translations.str("PROGRESS_DELETE")
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "H:mm:ss"; return f
    }()

    func show(on parent: NSWindow?) {
        started = Date()
        window.title = operationName
        if let p = parent { p.beginSheet(window) } else { window.center(); window.makeKeyAndOrderFront(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func close() {
        timer?.invalidate()
        refresh()
        if let p = window.sheetParent { p.endSheet(window) } else { window.orderOut(nil) }
    }

    @objc func cancel(_ sender: Any?) {
        lock.lock(); _cancelled = true; lock.unlock()
        form?.button("CancelItem")?.isEnabled = false
    }

    func setTotals(bytes: UInt64, count: Int) {
        lock.lock(); totalSize = bytes; countTotal = count; indeterminate = false; lock.unlock()
    }
    func begin(file: String, target: String, size: UInt64) {
        lock.lock(); curFile = file; curTarget = target; fileSize = size; fileDone = 0; lock.unlock()
    }
    func scanning(_ s: String) { lock.lock(); curFile = s; curTarget = ""; lock.unlock() }
    /// ファイル内の進み具合。中止なら false
    func update(fileBytes: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        fileDone = fileBytes
        return !_cancelled
    }
    func finishFile() {
        lock.lock(); totalDone += fileSize; fileDone = 0; countDone += 1; lock.unlock()
    }
    func skipBytes(_ n: UInt64) { lock.lock(); totalDone += n; countDone += 1; lock.unlock() }

    private func refresh() {
        lock.lock()
        let (f, t, fd, fs, td, ts, cd, ct, ind) = (curFile, curTarget, fileDone, fileSize, totalDone, totalSize, countDone, countTotal, indeterminate)
        lock.unlock()
        guard let form = form else { return }
        if !frames.isEmpty {
            frameIndex = (frameIndex + 1) % frames.count
            (form["AnimationPaintBox"] as? NSImageView)?.image = frames[frameIndex]
        }
        form.label("FileLabel")?.stringValue = f
        form.label("TargetPathLabel")?.stringValue = t.isEmpty ? "" : (t as NSString).deletingLastPathComponent
        let done = td + fd
        let overall: Int? = ind ? nil : Int(ts > 0 ? Double(done) * 100 / Double(ts) : (ct > 0 ? Double(cd) * 100 / Double(ct) : 0))
        if let op = form["OperationProgress"] as? NSProgressIndicator {
            if let o = overall {
                if op.isIndeterminate { op.stopAnimation(nil); op.isIndeterminate = false }
                op.doubleValue = Double(o)
                op.toolTip = "\(o)%"
            } else if !op.isIndeterminate {
                op.isIndeterminate = true
                op.startAnimation(nil)
            }
        }
        window.title = overall.map { "\($0)% \(operationName)" } ?? operationName
        guard kind.isTransfer else { return }
        (form["FileProgress"] as? NSProgressIndicator)?.doubleValue = fs > 0 ? Double(fd) * 100 / Double(fs) : 0
        let el = Date().timeIntervalSince(started)
        let speed = el > 0.5 ? Double(done) / el : 0
        // 合計の大きさが分かったら、開始時間の代わりに残り時間
        let known = !ind
        form.setVisible("StartTimeLabelLabel", !known)
        form.setVisible("StartTimeLabel", !known)
        form.setVisible("TimeLeftLabelLabel", known)
        form.setVisible("TimeLeftLabel", known)
        if known {
            form.label("TimeLeftLabel")?.stringValue = speed > 0 && ts >= done
                ? ProgressSheet.duration(Double(ts - done) / speed) : Translations.str("PROGRESS_TIME_LEFT_CALCULATING")
        }
        form.label("TimeElapsedLabel")?.stringValue = ProgressSheet.duration(el)
        form.label("BytesTransferredLabel")?.stringValue = UI.size(done)
        form.label("CPSLabel")?.stringValue = "\(UI.size(UInt64(speed)))/s"
    }

    static func duration(_ s: Double) -> String {
        let n = Int(s)
        return String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
}


/// アップロード / ダウンロード (フォルダは中身ごと)
final class TransferJob {
    enum Kind { case upload, download }

    struct Item {
        var src: String
        var dst: String
        var isDir: Bool
        var size: UInt64
        var mtime: Date?
        var permissions: UInt32?
    }

    let session: Session
    let kind: Kind
    let move: Bool
    let targetDir: String
    let localSources: [URL]
    let remoteDir: String
    let remoteEntries: [FileEntry]
    var preserveTime = Prefs.preserveTime
    private var overwriteMode: Dialogs.Overwrite?
    private var skipAllErrors = false
    let sheet: ProgressSheet

    /// アップロード
    init(session: Session, upload urls: [URL], to remoteDir: String, move: Bool) {
        self.session = session; kind = .upload; self.move = move; targetDir = remoteDir
        localSources = urls; self.remoteDir = ""; remoteEntries = []
        sheet = ProgressSheet(kind: .upload(move: move))
    }

    /// ダウンロード
    init(session: Session, download entries: [FileEntry], from dir: String, to localDir: String, move: Bool) {
        self.session = session; kind = .download; self.move = move; targetDir = localDir
        localSources = []; remoteDir = dir; remoteEntries = entries
        sheet = ProgressSheet(kind: .download(move: move))
    }

    /// 実行する。終わったら転送できたものの名前 (最上位) を返す
    func start(parent: NSWindow?, completion: @escaping (_ names: [String], _ error: Error?) -> Void) {
        sheet.show(on: parent)
        session.queue.async {
            var names: [String] = []
            var err: Error?
            do { names = try self.runSync() } catch { err = error }
            DispatchQueue.main.async {
                self.sheet.close()
                completion(names, err)
            }
        }
    }

    /// session.queue の上で同期に実行する (Finder へのドラッグなどからも使う)
    func runSync() throws -> [String] {
        let items = try scan()
        let files = items.filter { !$0.isDir }
        sheet.setTotals(bytes: files.reduce(0) { $0 + $1.size }, count: files.count)
        var done: [String] = []
        var failedDirs = Set<String>()
        for it in items {
            if sheet.cancelled { throw RemoteError.cancelled }
            if it.isDir {
                do { try makeDir(it) } catch { if !(try handleError(error, it)) { failedDirs.insert(it.src) } }
                continue
            }
            if failedDirs.contains(where: { it.src.hasPrefix($0 + "/") }) { continue }
            if try transferFile(it) { done.append(it.src) }
        }
        // 移動なら空になったディレクトリを消す (深いほうから)
        if move {
            for it in items.reversed() where it.isDir {
                if kind == .upload { Darwin.rmdir(it.src) }  // 中身が残っていれば消えない
                else { _ = try? session.sync { try $0.removeDirectory(it.src) } }
            }
        }
        let tops = kind == .upload ? localSources.map { $0.lastPathComponent } : remoteEntries.map(\.name)
        return tops
    }

    // MARK: 一覧づくり

    private func scan() throws -> [Item] {
        var items: [Item] = []
        if kind == .upload {
            let fm = FileManager.default
            for u in localSources {
                let base = u.path
                let dstBase = RemotePath.join(targetDir, u.lastPathComponent)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: base, isDirectory: &isDir) else { continue }
                if !isDir.boolValue {
                    items.append(localItem(base, dstBase))
                    continue
                }
                items.append(Item(src: base, dst: dstBase, isDir: true, size: 0, mtime: nil, permissions: nil))
                sheet.scanning(base)
                if let en = fm.enumerator(atPath: base) {
                    while let rel = en.nextObject() as? String {
                        if sheet.cancelled { throw RemoteError.cancelled }
                        let full = (base as NSString).appendingPathComponent(rel)
                        var d: ObjCBool = false
                        fm.fileExists(atPath: full, isDirectory: &d)
                        let dst = RemotePath.join(dstBase, rel)
                        if d.boolValue { items.append(Item(src: full, dst: dst, isDir: true, size: 0, mtime: nil, permissions: nil)) }
                        else { items.append(localItem(full, dst)) }
                    }
                }
            }
        } else {
            func walk(_ dir: String, _ e: FileEntry, _ dst: String) throws {
                if sheet.cancelled { throw RemoteError.cancelled }
                let src = RemotePath.join(dir, e.name)
                if e.isDirectory {
                    items.append(Item(src: src, dst: dst, isDir: true, size: 0, mtime: e.mtime, permissions: e.permissions))
                    sheet.scanning(src)
                    for c in try session.sync({ try $0.list(src) }) {
                        try walk(src, c, (dst as NSString).appendingPathComponent(c.name))
                    }
                } else {
                    items.append(Item(src: src, dst: dst, isDir: false, size: e.size, mtime: e.mtime, permissions: e.permissions))
                }
            }
            for e in remoteEntries { try walk(remoteDir, e, (targetDir as NSString).appendingPathComponent(e.name)) }
        }
        return items
    }

    private func localItem(_ path: String, _ dst: String) -> Item {
        let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        return Item(src: path, dst: dst, isDir: false, size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                    mtime: a[.modificationDate] as? Date,
                    permissions: (a[.posixPermissions] as? NSNumber)?.uint32Value)
    }

    // MARK: 実行

    private func makeDir(_ it: Item) throws {
        if kind == .upload {
            if (try? session.sync({ try $0.stat(it.dst) }))?.isDirectory == true { return }
            try session.sync { try $0.makeDirectory(it.dst) }
        } else {
            try FileManager.default.createDirectory(atPath: it.dst, withIntermediateDirectories: true)
        }
    }

    /// 1 つのファイルを送る。送ったら true、とばしたら false
    private func transferFile(_ it: Item) throws -> Bool {
        while true {
            do {
                // 上書きの確認
                let existing: FileEntry?
                if kind == .upload {
                    existing = try? session.sync { try $0.stat(it.dst) }
                } else if let a = try? FileManager.default.attributesOfItem(atPath: it.dst) {
                    existing = FileEntry(name: it.dst, isDirectory: (a[.type] as? FileAttributeType) == .typeDirectory,
                                         size: (a[.size] as? NSNumber)?.uint64Value ?? 0, mtime: a[.modificationDate] as? Date)
                } else { existing = nil }
                if let ex = existing {
                    if ex.isDirectory { throw RemoteError("\(it.dst): 同じ名前のフォルダがあります") }
                    if !shouldOverwrite(it, ex) { sheet.skipBytes(it.size); return false }
                }
                sheet.begin(file: it.src, target: it.dst, size: it.size)
                if kind == .upload {
                    try session.sync { fs in
                        try fs.upload(URL(fileURLWithPath: it.src), to: it.dst) { self.sheet.update(fileBytes: $0) }
                        if preserveTime, let m = it.mtime { try? fs.setModificationTime(it.dst, m) }
                    }
                    if move { try FileManager.default.removeItem(atPath: it.src) }
                } else {
                    let url = URL(fileURLWithPath: it.dst)
                    try session.sync { fs in
                        try fs.download(it.src, to: url, offset: 0) { self.sheet.update(fileBytes: $0) }
                    }
                    if preserveTime, let m = it.mtime {
                        try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: it.dst)
                    }
                    if move { try session.sync { try $0.removeFile(it.src) } }
                }
                sheet.finishFile()
                return true
            } catch let e as RemoteError where e.isCancelled {
                // 途中まで書いたファイルは消す
                if kind == .download { try? FileManager.default.removeItem(atPath: it.dst) }
                throw e
            } catch {
                if try handleError(error, it) { continue }
                sheet.skipBytes(it.size)
                return false
            }
        }
    }

    /// エラーのとき: 再試行なら true、とばすなら false、中止なら throw
    private func handleError(_ error: Error, _ it: Item) throws -> Bool {
        if skipAllErrors { return false }
        let choice: Int = Session.askOnMain {
            let a = NSAlert()
            // WinSCP のファイル操作のエラー (COPY_ERROR + 詳細、ボタンは スキップ / すべてスキップ / 再試行 / 中止)
            a.messageText = Translations.fmt("COPY_ERROR", it.src)
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            for t in [Translations.clean(Translations.str("SKIP_BUTTON")), Translations.clean(Translations.str("SKIP_ALL_BUTTON")),
                      Dialogs.vcl("Retry"), Dialogs.vcl("Abort")] { a.addButton(withTitle: t) }
            return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        } ?? 3
        switch choice {
        case 0: return false
        case 1: skipAllErrors = true; return false
        case 2: return true
        default: throw RemoteError.cancelled
        }
    }

    private func shouldOverwrite(_ it: Item, _ ex: FileEntry) -> Bool {
        let src = FileEntry(name: it.src, isDirectory: false, size: it.size, mtime: it.mtime)
        func newer() -> Bool { (it.mtime ?? .distantPast) > (ex.mtime ?? .distantPast) }
        switch overwriteMode {
        case .yesAll?: return true
        case .noAll?: return false
        case .newer?: return newer()
        default: break
        }
        if !Prefs.confirmOverwrite { return true }
        let name = (it.dst as NSString).lastPathComponent
        let r = Session.askOnMain { Dialogs.overwrite(name: name, source: src, target: ex, toRemote: self.kind == .upload) } ?? .cancel
        switch r {
        case .yes: return true
        case .no: return false
        case .yesAll, .noAll, .newer:
            overwriteMode = r
            return shouldOverwrite(it, ex)
        case .cancel:
            sheet.cancel(nil)
            return false
        }
    }
}

/// リモートの削除 (フォルダは中身ごと)
enum RemoteDelete {
    static func run(session: Session, dir: String, entries: [FileEntry], parent: NSWindow?, completion: @escaping (Error?) -> Void) {
        let sheet = ProgressSheet(kind: .delete)
        sheet.show(on: parent)
        session.queue.async {
            var err: Error?
            do {
                func rm(_ path: String, _ e: FileEntry) throws {
                    if sheet.cancelled { throw RemoteError.cancelled }
                    sheet.scanning(path)
                    if e.isDirectory && !e.isSymlink {
                        for c in try session.sync({ try $0.list(path) }) { try rm(RemotePath.join(path, c.name), c) }
                        try session.sync { try $0.removeDirectory(path) }
                    } else {
                        try session.sync { try $0.removeFile(path) }
                    }
                }
                for e in entries { try rm(RemotePath.join(dir, e.name), e) }
            } catch { err = error }
            DispatchQueue.main.async { sheet.close(); completion(err) }
        }
    }
}
