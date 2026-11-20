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
        let sheet = ProgressSheet(kind: .download(move: false))
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

/// クロージャを target/action に使うための入れ物
final class ClosureTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}


/// コマンドの実行 (WinSCP の「コンソール」: Console.dfm)
final class CommandWindow: NSWindowController, NSWindowDelegate {
    static var open: [CommandWindow] = []
    let session: Session
    var directory: String { didSet { form.label("DirectoryLabel")?.stringValue = directory } }
    let onDone: () -> Void
    private let form: DFMForm
    private var targets: [ClosureTarget] = []
    private var output: NSTextView? { form.textView("OutputMemo") }
    private var input: NSComboBox? { form.combo("CommandEdit") }
    static let historyKey = "WinSCPConsoleHistory"

    static func show(session: Session, directory: String, onDone: @escaping () -> Void) {
        if let w = open.first(where: { $0.session === session }) {
            w.directory = directory
            w.showWindow(nil)
            return
        }
        guard let w = CommandWindow(session: session, directory: directory, onDone: onDone) else { return }
        open.append(w)
        w.showWindow(nil)
    }

    init?(session: Session, directory: String, onDone: @escaping () -> Void) {
        guard let f = DFMForm("Console.dfm") else { return nil }
        self.session = session; self.directory = directory; self.onDone = onDone
        form = f
        let w = NSWindow(contentRect: f.view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = f.caption
        w.contentMinSize = NSSize(width: f.root.int("Constraints.MinWidth") ?? 420, height: f.root.int("Constraints.MinHeight") ?? 250)
        w.contentView = f.view
        super.init(window: w)
        w.delegate = self
        (f["Image"] as? NSImageView)?.image = WinSCPImages.dialog("Open console window")
        f.label("DirectoryLabel")?.stringValue = directory
        f.label("DirectoryLabel")?.lineBreakMode = .byTruncatingHead
        if let o = output {
            o.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            o.backgroundColor = .windowBackgroundColor
            o.isEditable = false
        }
        if let c = input {
            c.addItems(withObjectValues: UserDefaults.standard.stringArray(forKey: CommandWindow.historyKey) ?? [])
            c.stringValue = ""
            c.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        // 実行 (既定のボタン) と 閉じる
        let exec = ClosureTarget { [weak self] in self?.execute(nil) }
        let close = ClosureTarget { [weak self] in self?.window?.performClose(nil) }
        // 欄で Return を押したら実行 (一覧から選んだだけでは実行しない)
        let enter = ClosureTarget { [weak self] in if NSApp.currentEvent?.type == .keyDown { self?.execute(nil) } }
        input?.target = enter
        input?.action = #selector(ClosureTarget.fire)
        targets = [exec, close, enter]
        f.button("ExecuteButton")?.target = exec
        f.button("ExecuteButton")?.action = #selector(ClosureTarget.fire)
        f.button("CancelBtn")?.target = close
        f.button("CancelBtn")?.action = #selector(ClosureTarget.fire)
        if let hb = f.button("HelpButton"), let u = URL(string: "https://winscp.net/eng/docs/ui_console") {
            let h = ClosureTarget { NSWorkspace.shared.open(u) }
            targets.append(h)
            hb.target = h
            hb.action = #selector(ClosureTarget.fire)
        }
        w.center()
        w.initialFirstResponder = input
    }
    required init?(coder: NSCoder) { fatalError() }

    private func append(_ s: String) {
        guard let o = output else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]
        o.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
        o.scrollToEndOfDocument(nil)
    }

    @objc func execute(_ sender: Any?) {
        guard let input = input else { return }
        let cmd = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        // 履歴 (THistoryComboBox の Commands)
        var h = UserDefaults.standard.stringArray(forKey: CommandWindow.historyKey) ?? []
        h.removeAll { $0 == cmd }
        h.insert(cmd, at: 0)
        h = Array(h.prefix(30))
        UserDefaults.standard.set(h, forKey: CommandWindow.historyKey)
        input.removeAllItems()
        input.addItems(withObjectValues: h)
        input.stringValue = ""
        // WinSCP と同じく "$ コマンド" の行のあとに出力
        append("$ \(cmd)\n")
        input.isEnabled = false
        form.button("ExecuteButton")?.isEnabled = false
        let dir = directory
        session.run({ try $0.runCommand(cmd, in: dir) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let out): self.append(out.hasSuffix("\n") || out.isEmpty ? out : out + "\n")
            case .failure(let e): self.append("\(e.localizedDescription)\n")
            }
            input.isEnabled = true
            self.form.button("ExecuteButton")?.isEnabled = true
            self.window?.makeFirstResponder(input)
            self.onDone()
        }
    }

    func windowWillClose(_ notification: Notification) { CommandWindow.open.removeAll { $0 === self } }
}
