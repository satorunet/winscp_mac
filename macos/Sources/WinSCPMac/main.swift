import AppKit
import ScpCore

// ssh から askpass として呼ばれたときは、質問を本体に渡して終わる (GUI は起動しない)
Askpass.runHelperIfRequested()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminating = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // 環境設定のテーマ (Configuration\\Interface\\DarkTheme)
        Prefs.applyTheme()
        buildMenu()
        // WINSCPMAC_RENDER=<dir> WINSCPMAC_FORMS=Login.dfm,Copy.dfm: .dfm からの画面を PNG にして終わる
        if let dir = ProcessInfo.processInfo.environment["WINSCPMAC_RENDER"] {
            SelfTest.dir = dir
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in (ProcessInfo.processInfo.environment["WINSCPMAC_FORMS"] ?? "").split(separator: ",") {
                // "SiteAdvanced:<sftp|scp|ftp|ftps>:<シート名>": 高度なサイトの設定の、そのページ
                if f.hasPrefix("SiteAdvanced:") {
                    guard let v = SiteAdvancedDialog.renderForTest(String(f)) else { SelfTest.log.append("NG \(f)"); continue }
                    let w = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    w.contentView = v
                    w.orderFront(nil)
                    SelfTest.snap(w, f.replacingOccurrences(of: ":", with: "_"))
                    continue
                }
                guard let form = DFMForm(String(f)) else { SelfTest.log.append("NG \(f)"); continue }
                let w = NSWindow(contentRect: form.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = form.view
                w.orderFront(nil)
                SelfTest.snap(w, String(f))
                SelfTest.log.append("\(f): \(form.caption) \(Int(form.view.frame.width))x\(Int(form.view.frame.height)) views=\(form.views.count)")
            }
            PreferencesDialog.renderForTest(dir: dir)
            SelfTest.finish()
        }
        if let dir = ProcessInfo.processInfo.environment["WINSCPMAC_SNAPSHOT"] {
            SelfTest.run(dir: dir)
            return
        }
        // 前回の一時ファイル (編集用) を片付ける
        try? FileManager.default.removeItem(at: EditManager.baseDir)
        // 更新の確認 (環境設定 → 更新 の間隔が来ていれば)。新しい版があれば、ログイン画面の前に知らせる
        Updater.shared.checkOnStartup {
            LoginWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { WinSCPImport.offerOnFirstLaunch() }
        }
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

    @objc func showPreferences(_ sender: Any?) { PreferencesDialog.show(parent: NSApp.keyWindow) }

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
        // WinSCP のコマンダーのメニュー (ScpCommander.dfm の MenuToolbar と NonVisual.dfm のアクションから)
        // ローカル / マーク / ファイル / コマンド / タブ / オプション / リモート / ヘルプ
        let winscp = WinSCPMenu.topMenus()
        let helpItem = winscp.last
        for t in winscp.dropLast() { main.addItem(t) }
        _ = add("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        let win = add("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大/縮小", #selector(NSWindow.performZoom(_:))),
            item("閉じる", #selector(closeKeyWindow(_:)), "w"),
            sep(),
            item("すべてを手前に移動", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win
        if let h = helpItem {
            main.addItem(h)
            NSApp.helpMenu = h.submenu
        }
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
