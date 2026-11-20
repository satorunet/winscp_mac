import AppKit
import ScpCore

/// リモートのファイルを手元のエディタで編集する (WinSCP の外部エディタと同じ)。
/// 一時フォルダに落としてエディタで開き、保存されるたびにアップロードし直す。
final class EditManager {
    final class Item {
        let session: Session
        let remotePath: String
        let local: URL
        var lastMtime: Date?
        var uploading = false
        init(session: Session, remotePath: String, local: URL) { self.session = session; self.remotePath = remotePath; self.local = local }
    }

    private var items: [Item] = []
    private var timer: Timer?
    private var notify: ((String) -> Void)?

    static var baseDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("net.satoru.winscpmac/edit", isDirectory: true)
    }

    var hasPending: Bool { items.contains { $0.uploading } }

    func edit(session: Session, dir: String, entry: FileEntry, parent: NSWindow?, notify: @escaping (String) -> Void) {
        self.notify = notify
        let remotePath = RemotePath.join(dir, entry.name)
        // 同じファイルをもう編集中ならそれを開くだけ
        if let it = items.first(where: { $0.remotePath == remotePath && $0.session === session }) {
            EditManager.openInEditor(it.local)
            return
        }
        let folder = EditManager.baseDir.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(entry.name)
        let sheet = ProgressSheet(title: "編集のためにダウンロード")
        sheet.show(on: parent)
        sheet.setTotals(bytes: entry.size, count: 1)
        sheet.begin(file: remotePath, target: local.path, size: entry.size)
        session.run({ fs in
            try fs.download(remotePath, to: local, offset: 0) { sheet.update(fileBytes: $0) }
        }) { [weak self] r in
            sheet.close()
            guard let self = self else { return }
            switch r {
            case .failure(let e):
                Dialogs.error(e)
                try? FileManager.default.removeItem(at: folder)
            case .success:
                let it = Item(session: session, remotePath: remotePath, local: local)
                it.lastMtime = EditManager.mtime(local)
                self.items.append(it)
                EditManager.openInEditor(local)
                notify("編集中: \(remotePath) (保存すると自動でアップロードします)")
                self.startTimer()
            }
        }
    }

    static func mtime(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// 設定したエディタ (無ければ種類ごとの既定のアプリ、それも無ければテキストエディット) で開く
    static func openInEditor(_ url: URL) {
        let conf = NSWorkspace.OpenConfiguration()
        var app: URL?
        if !Prefs.editorApp.isEmpty { app = URL(fileURLWithPath: Prefs.editorApp) }
        else if let def = NSWorkspace.shared.urlForApplication(toOpen: url) { app = def }
        let editor = app ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: conf) { _, err in
            if let e = err { DispatchQueue.main.async { Dialogs.error(e, title: "エディタで開けません") } }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        for it in items where !it.uploading {
            guard let m = EditManager.mtime(it.local), m != it.lastMtime else { continue }
            it.lastMtime = m
            it.uploading = true
            notify?("アップロード中: \(it.remotePath)")
            it.session.run({ fs in try fs.upload(it.local, to: it.remotePath) { _ in true } }) { [weak self] r in
                it.uploading = false
                switch r {
                case .success: self?.notify?("アップロードしました: \(it.remotePath)  (\(UI.dateFormatter.string(from: Date())))")
                case .failure(let e): Dialogs.error(e, title: "\(it.remotePath) をアップロードできません")
                }
            }
        }
    }

    func stopAll() {
        timer?.invalidate()
        timer = nil
        // 最後の変更を拾う
        check()
        items.removeAll()
    }
}

/// プロパティ (パーミッションの変更)
enum PropertiesDialog {
    static func run(entries: [FileEntry], dir: String, remote: Bool, parent: NSWindow?, apply: @escaping (UInt32, Bool) -> Void) {
        let e = entries[0]
        let a = NSAlert()
        a.messageText = entries.count == 1 ? e.name : "\(entries.count) 個の項目"
        let dirs = entries.filter(\.isDirectory).count
        var info = "場所: \(dir)\n"
        if entries.count == 1 {
            info += "種類: \(e.isDirectory ? "フォルダ" : "ファイル")\(e.isSymlink ? " (シンボリックリンク\(e.linkTarget.map { " → \($0)" } ?? ""))" : "")\n"
            if !e.isDirectory { info += "サイズ: \(UI.size(e.size)) (\(FilePanel.numberFormatter.string(from: NSNumber(value: e.size)) ?? "") バイト)\n" }
            if let m = e.mtime { info += "更新日時: \(UI.dateFormatter.string(from: m))\n" }
            if !e.owner.isEmpty { info += "所有者: \(e.owner)    グループ: \(e.group)\n" }
        } else {
            let size = entries.reduce(UInt64(0)) { $0 + $1.size }
            info += "ファイル \(entries.count - dirs) 個、フォルダ \(dirs) 個、\(UI.size(size))\n"
        }
        a.informativeText = info
        a.icon = NSImage(named: e.isDirectory ? NSImage.folderName : NSImage.multipleDocumentsName)

        // パーミッションのチェックボックス
        let mode = e.permissions ?? 0o644
        var boxes: [NSButton] = []
        let titles = ["読み取り", "書き込み", "実行"]
        var rows: [[NSView]] = [[UI.label(""), UI.label("読み取り"), UI.label("書き込み"), UI.label("実行")]]
        for (r, who) in ["所有者", "グループ", "その他"].enumerated() {
            var row: [NSView] = [UI.label(who)]
            for c in 0..<3 {
                let bit = UInt32(1) << UInt32(8 - (r * 3 + c))
                let b = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                b.state = mode & bit != 0 ? .on : .off
                b.toolTip = "\(who) \(titles[c])"
                boxes.append(b)
                row.append(b)
            }
            rows.append(row)
        }
        let special = [("SUID", UInt32(0o4000)), ("SGID", UInt32(0o2000)), ("Sticky", UInt32(0o1000))].map { (t, bit) -> NSButton in
            UI.checkbox(t, mode & bit != 0)
        }
        rows.append([UI.label("特殊")] + special)
        let grid = UI.grid(rows)
        let octal = UI.field(String(format: "%04o", mode & 0o7777), width: 70)
        let recursive = UI.checkbox("サブフォルダ内のファイルにも適用する", false)
        recursive.isHidden = dirs == 0 || !remote
        func current() -> UInt32 {
            var m: UInt32 = 0
            for (i, b) in boxes.enumerated() where b.state == .on { m |= UInt32(1) << UInt32(8 - i) }
            for (i, b) in special.enumerated() where b.state == .on { m |= [0o4000, 0o2000, 0o1000][i] }
            return m
        }
        let sync = ClosureTarget {
            octal.stringValue = String(format: "%04o", current())
        }
        for b in boxes + special { b.target = sync; b.action = #selector(ClosureTarget.fire) }
        let fromOctal = ClosureTarget {
            guard let m = UInt32(octal.stringValue, radix: 8) else { return }
            for (i, b) in boxes.enumerated() { b.state = m & (UInt32(1) << UInt32(8 - i)) != 0 ? .on : .off }
            for (i, b) in special.enumerated() { b.state = m & [0o4000, 0o2000, 0o1000][i] != 0 ? .on : .off }
        }
        octal.target = fromOctal
        octal.action = #selector(ClosureTarget.fire)
        let octalRow = NSStackView(views: [UI.label("8 進数:"), octal])
        let v = NSStackView(views: [grid, octalRow, recursive])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
        a.accessoryView = v
        let editable = remote || entries.allSatisfy { $0.permissions != nil }
        a.addButton(withTitle: editable ? "OK" : "閉じる")
        if editable { a.addButton(withTitle: "キャンセル") }
        let r = a.runModal()
        withExtendedLifetime([sync, fromOctal]) {}
        guard editable, r == .alertFirstButtonReturn else { return }
        // 8 進数の欄を直接書き換えた場合も拾う
        let m = UInt32(octal.stringValue, radix: 8) ?? current()
        let changed = entries.contains { ($0.permissions ?? 0) != m } || recursive.state == .on
        if changed { apply(m, recursive.state == .on) }
    }
}

/// クロージャを target/action に使うための入れ物
final class ClosureTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

/// コマンドの実行 (WinSCP の「コンソール」)
final class CommandWindow: NSWindowController, NSWindowDelegate {
    static var open: [CommandWindow] = []
    let session: Session
    var directory: String
    let onDone: () -> Void
    private let output = NSTextView()
    private let input = NSTextField()
    private var history: [String] = []

    static func show(session: Session, directory: String, onDone: @escaping () -> Void) {
        if let w = open.first(where: { $0.session === session }) {
            w.directory = directory
            w.showWindow(nil)
            return
        }
        let w = CommandWindow(session: session, directory: directory, onDone: onDone)
        open.append(w)
        w.showWindow(nil)
    }

    init(session: Session, directory: String, onDone: @escaping () -> Void) {
        self.session = session; self.directory = directory; self.onDone = onDone
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "コンソール - \(session.title)"
        super.init(window: w)
        w.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.autoresizingMask = [.width]
        output.isVerticallyResizable = true
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output
        input.placeholderString = "コマンドを入力して Return (リモートの \(directory) で実行)"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.target = self
        input.action = #selector(execute(_:))
        let note = UI.label(session.site.proto == .ftp ? "FTP ではサーバーへの生のコマンドを送ります。" : "1 回ごとに新しいシェルで実行されます (cd は次のコマンドに引き継がれません)。", size: 11)
        note.textColor = .secondaryLabelColor
        let v = NSStackView(views: [scroll, input, note])
        v.orientation = .vertical
        v.alignment = .leading
        v.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for x in [scroll, input] { x.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -16).isActive = true }
        w.contentView = v
        w.center()
        w.initialFirstResponder = input
    }
    required init?(coder: NSCoder) { fatalError() }

    private func append(_ s: String, bold: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        output.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
        output.scrollToEndOfDocument(nil)
    }

    @objc func execute(_ sender: Any?) {
        let cmd = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        input.stringValue = ""
        history.append(cmd)
        append("\(directory)$ \(cmd)\n", bold: true)
        input.isEnabled = false
        let dir = directory
        session.run({ try $0.runCommand(cmd, in: dir) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let out): self.append(out.hasSuffix("\n") || out.isEmpty ? out : out + "\n")
            case .failure(let e): self.append("エラー: \(e.localizedDescription)\n")
            }
            self.input.isEnabled = true
            self.window?.makeFirstResponder(self.input)
            self.onDone()
        }
    }

    func windowWillClose(_ notification: Notification) { CommandWindow.open.removeAll { $0 === self } }
}
