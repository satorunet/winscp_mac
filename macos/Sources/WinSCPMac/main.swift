import AppKit
import ScpCore

// ssh から askpass として呼ばれたときは、質問を本体に渡して終わる (GUI は起動しない)
Askpass.runHelperIfRequested()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminating = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        if let dir = ProcessInfo.processInfo.environment["WINSCPMAC_SNAPSHOT"] {
            SelfTest.run(dir: dir)
            return
        }
        // 前回の一時ファイル (編集用) を片付ける
        try? FileManager.default.removeItem(at: EditManager.baseDir)
        LoginWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { WinSCPImport.offerOnFirstLaunch() }
    }

    /// WinSCP.ini / .reg をアプリのアイコンにドロップしたら取り込む
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ext == "ini" || ext == "reg", FileManager.default.fileExists(atPath: filename) else { return false }
        DispatchQueue.main.async {
            LoginWindowController.shared.showWindow(nil)
            WinSCPImport.importFile(URL(fileURLWithPath: filename))
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { LoginWindowController.shared.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = CommanderWindowController.all.count
        if n > 0 && Prefs.confirmDisconnect && ProcessInfo.processInfo.environment["WINSCPMAC_SNAPSHOT"] == nil {
            guard Dialogs.confirm("\(n) 個のセッションを終了して、WinSCP Mac を終了しますか?", ok: "終了") else { return .terminateCancel }
        }
        terminating = true
        for c in CommanderWindowController.all { c.window?.close() }
        return .terminateNow
    }

    @objc func newSession(_ sender: Any?) {
        LoginWindowController.shared.showWindow(nil)
    }

    @objc func showPreferences(_ sender: Any?) { PreferencesWindow.shared.showWindow(nil) }

    @objc func openHomepage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/satorunet/winscp_mac")!)
    }

    // MARK: メニュー

    private func fkey(_ n: Int) -> String { String(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!)) }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return m
        }
        let sep = { NSMenuItem.separator() }
        let services = NSMenu()
        let servicesItem = item("サービス", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        _ = add("WinSCP Mac", [
            item("WinSCP Mac について", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            item("設定…", #selector(showPreferences(_:)), ","),
            sep(), servicesItem, sep(),
            item("WinSCP Mac を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("WinSCP Mac を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("セッション", [
            item("新しいセッション…", #selector(newSession(_:)), "n"),
            item("サイトマネージャー…", #selector(newSession(_:)), "n", [.command, .shift]),
            sep(),
            item("コンソールを開く…", #selector(CommanderWindowController.runCommand(_:)), "t"),
            item("ターミナルで開く", #selector(CommanderWindowController.openTerminal(_:)), "p"),
            sep(),
            item("セッションを閉じる", #selector(CommanderWindowController.closeSession(_:)), "w"),
        ])
        _ = add("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = add("ファイル", [
            item("開く", #selector(CommanderWindowController.openSelected(_:)), "o", [.command, .shift]),
            item("編集", #selector(CommanderWindowController.editFile(_:)), fkey(4), []),
            sep(),
            item("コピー (転送)…", #selector(CommanderWindowController.copyFiles(_:)), fkey(5), []),
            item("移動 (転送して削除)…", #selector(CommanderWindowController.moveFiles(_:)), fkey(6), []),
            sep(),
            item("名前の変更…", #selector(CommanderWindowController.renameFile(_:)), fkey(2), []),
            item("フォルダの作成…", #selector(CommanderWindowController.makeFolder(_:)), fkey(7), []),
            item("削除…", #selector(CommanderWindowController.deleteFiles(_:)), fkey(8), []),
            sep(),
            item("プロパティ…", #selector(CommanderWindowController.showProperties(_:)), fkey(9), []),
            item("パスをコピー", #selector(CommanderWindowController.copyPath(_:)), "c", [.command, .option]),
            item("Finder で表示", #selector(CommanderWindowController.revealInFinder(_:)), "r", [.command, .shift]),
        ])
        _ = add("コマンド", [
            item("ディレクトリの比較", #selector(CommanderWindowController.compareDirectories(_:)), "="),
            item("もう一方のパネルへ", #selector(CommanderWindowController.switchPanel(_:))),
        ])
        _ = add("表示", [
            item("隠しファイルを表示", #selector(CommanderWindowController.toggleHidden(_:)), ".", [.command, .shift]),
            item("更新", #selector(CommanderWindowController.refreshPanels(_:)), "r"),
            sep(),
            item("ディレクトリを開く…", #selector(CommanderWindowController.goToRemote(_:)), "o"),
            item("親ディレクトリ", #selector(CommanderWindowController.panelUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
            item("ホームディレクトリ", #selector(CommanderWindowController.panelHome(_:)), "h", [.command, .shift]),
            item("ルートディレクトリ", #selector(CommanderWindowController.panelRoot(_:)), "\\"),
            item("戻る", #selector(CommanderWindowController.panelBack(_:)), "["),
            item("進む", #selector(CommanderWindowController.panelForward(_:)), "]"),
        ])
        let win = add("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大/縮小", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win
        let help = add("ヘルプ", [item("WinSCP Mac のホームページ", #selector(openHomepage(_:)))])
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}

extension CommanderWindowController {
    @objc func panelUp(_ sender: Any?) { activePanel.goUp(nil) }
    @objc func panelHome(_ sender: Any?) { activePanel.goHome(nil) }
    @objc func panelRoot(_ sender: Any?) { activePanel.goRoot(nil) }
    @objc func panelBack(_ sender: Any?) { activePanel.goBack(nil) }
    @objc func panelForward(_ sender: Any?) { activePanel.goForward(nil) }
}

/// 設定 (WinSCP の「環境設定」のうち、よく使うもの)
final class PreferencesWindow: NSWindowController {
    static let shared = PreferencesWindow()
    private let hidden = UI.checkbox("隠しファイルを表示する", Prefs.showHidden)
    private let confDelete = UI.checkbox("ファイルを削除する前に確認する", Prefs.confirmDelete)
    private let confOverwrite = UI.checkbox("ファイルを上書きする前に確認する", Prefs.confirmOverwrite)
    private let copyDialog = UI.checkbox("ドラッグ＆ドロップで転送するときに確認のダイアログを出す", Prefs.showCopyDialog)
    private let keepTime = UI.checkbox("転送するときに更新日時を保持する", Prefs.preserveTime)
    private let confDisc = UI.checkbox("セッションを閉じる前に確認する", Prefs.confirmDisconnect)
    private let editorLabel = UI.label("")
    private let terminalLabel = UI.label("")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "設定"
        super.init(window: w)
        for c in [hidden, confDelete, confOverwrite, copyDialog, keepTime, confDisc] {
            c.target = self; c.action = #selector(changed(_:))
        }
        let editorRow = NSStackView(views: [editorLabel, UI.button("選ぶ…", self, #selector(chooseEditor(_:))), UI.button("既定に戻す", self, #selector(resetEditor(_:)))])
        let termRow = NSStackView(views: [terminalLabel, UI.button("選ぶ…", self, #selector(chooseTerminal(_:))), UI.button("既定に戻す", self, #selector(resetTerminal(_:)))])
        let v = NSStackView(views: [
            UI.label("パネル", bold: true), hidden,
            UI.label("確認", bold: true), confDelete, confOverwrite, copyDialog, confDisc,
            UI.label("転送", bold: true), keepTime,
            UI.label("編集 (F4) に使うアプリ", bold: true), editorRow,
            UI.label("ターミナル (⌘P) に使うアプリ", bold: true), termRow,
        ])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        w.contentView = v
        w.center()
        refreshLabels()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refreshLabels() {
        editorLabel.stringValue = Prefs.editorApp.isEmpty ? "ファイルの種類ごとの既定のアプリ (無ければテキストエディット)" : (Prefs.editorApp as NSString).lastPathComponent
        terminalLabel.stringValue = Prefs.terminalApp.isEmpty ? "Tera Term Mac (無ければターミナル)" : (Prefs.terminalApp as NSString).lastPathComponent
    }

    @objc func changed(_ sender: Any?) {
        Prefs.showHidden = hidden.state == .on
        Prefs.confirmDelete = confDelete.state == .on
        Prefs.confirmOverwrite = confOverwrite.state == .on
        Prefs.showCopyDialog = copyDialog.state == .on
        Prefs.preserveTime = keepTime.state == .on
        Prefs.confirmDisconnect = confDisc.state == .on
        for c in CommanderWindowController.all { c.local.applyFilterAndSort(); c.remote.applyFilterAndSort() }
    }

    override func showWindow(_ sender: Any?) {
        hidden.state = Prefs.showHidden ? .on : .off
        copyDialog.state = Prefs.showCopyDialog ? .on : .off
        keepTime.state = Prefs.preserveTime ? .on : .off
        confDisc.state = Prefs.confirmDisconnect ? .on : .off
        super.showWindow(sender)
    }

    private func chooseApp() -> String? {
        let o = NSOpenPanel()
        o.directoryURL = URL(fileURLWithPath: "/Applications")
        o.allowedFileTypes = ["app"]
        return o.runModal() == .OK ? o.url?.path : nil
    }
    @objc func chooseEditor(_ sender: Any?) { if let p = chooseApp() { Prefs.editorApp = p; refreshLabels() } }
    @objc func resetEditor(_ sender: Any?) { Prefs.editorApp = ""; refreshLabels() }
    @objc func chooseTerminal(_ sender: Any?) { if let p = chooseApp() { Prefs.terminalApp = p; refreshLabels() } }
    @objc func resetTerminal(_ sender: Any?) { Prefs.terminalApp = ""; refreshLabels() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
