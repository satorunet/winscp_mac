import AppKit
import ScpCore

/// 小さなダイアログ類 (どれもモーダル)
enum Dialogs {
    private static func alert(_ title: String, _ info: String = "", style: NSAlert.Style = .informational) -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = style
        return a
    }

    static func error(_ e: Error, title: String = "エラー", parent: NSWindow? = nil) {
        if let r = e as? RemoteError, r.isCancelled { return }
        let a = alert(title, e.localizedDescription, style: .warning)
        a.runModal()
    }

    static func message(_ title: String, _ info: String = "") {
        alert(title, info).runModal()
    }

    static func confirm(_ title: String, _ info: String = "", ok: String = "OK", style: NSAlert.Style = .warning) -> Bool {
        let a = alert(title, info, style: style)
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "キャンセル")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func password(prompt: String, parent: NSWindow?) -> String? {
        let a = alert("パスワード", prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        a.icon = NSApp.applicationIconImage
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    static func input(prompt: String, value: String = "", title: String = "入力", parent: NSWindow?) -> String? {
        let a = alert(title, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = f
        // 拡張子の前までを選んでおく (名前の変更で便利)
        DispatchQueue.main.async {
            if let ed = f.currentEditor() {
                let ns = value as NSString
                let ext = ns.pathExtension
                let len = ext.isEmpty || ns.length == ext.count + 1 ? ns.length : ns.length - ext.count - 1
                ed.selectedRange = NSRange(location: 0, length: len)
            }
        }
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    static func confirmHostKey(_ prompt: String, parent: NSWindow?) -> Bool {
        // ssh の文面: The authenticity of host ... can't be established. ED25519 key fingerprint is SHA256:...
        var lines = prompt.split(separator: "\n").map(String.init)
        lines.removeAll { $0.contains("(yes/no") }
        let a = alert("警告 - 未知のホスト鍵", """
        このサーバーのホスト鍵はまだ登録されていません。接続先が本当に意図したサーバーか確認してください。

        \(lines.joined(separator: "\n"))

        このサーバーを信頼して接続を続け、ホスト鍵を保存しますか?
        """, style: .warning)
        a.addButton(withTitle: "はい (鍵を保存)")
        a.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    static func confirmCertificate(summary: String, fingerprint: String, parent: NSWindow?) -> Bool {
        let a = alert("警告 - 証明書を確認できません", """
        サーバーの証明書を確認できませんでした。

        \(summary)

        SHA-256 指紋:
        \(fingerprint)

        この証明書を受け入れて接続を続けますか?
        """, style: .warning)
        a.addButton(withTitle: "はい")
        a.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    enum Overwrite { case yes, yesAll, no, noAll, newer, cancel }

    /// 上書きの確認 (WinSCP の TTerminal::ConfirmFileOverwrite: LOCAL_FILE_OVERWRITE2 / REMOTE_FILE_OVERWRITE2
    /// + FILE_OVERWRITE_DETAILS、ボタンは はい / すべてはい / 新しいほうのみ / いいえ / すべていいえ / キャンセル、
    /// 「次回は表示しない」)
    static func overwrite(name: String, source: FileEntry, target: FileEntry, toRemote: Bool) -> Overwrite {
        let nf = FilePanel.numberFormatter
        func size(_ e: FileEntry) -> String { nf.string(from: NSNumber(value: e.size)) ?? "\(e.size)" }
        func time(_ e: FileEntry) -> String { e.mtime.map { UI.dateFormatter.string(from: $0) } ?? Translations.str("TIME_UNKNOWN") }
        let msg = Translations.fmt(toRemote ? "REMOTE_FILE_OVERWRITE2" : "LOCAL_FILE_OVERWRITE2", name, name)
        let (main, rest) = Translations.mainInstructions(msg)
        let details = Translations.fmt("FILE_OVERWRITE_DETAILS", rest, size(source), time(source), size(target), time(target))
        let a = alert(main.isEmpty ? Vcl("Confirm") : main, details, style: .warning)
        let buttons: [(String, Overwrite)] = [
            (Vcl("Yes"), .yes), (Vcl("YesToAll"), .yesAll), (Translations.clean(Translations.str("YES_TO_NEWER_BUTTON")), .newer),
            (Vcl("No"), .no), (Vcl("NoToAll"), .noAll), (Vcl("Cancel"), .cancel),
        ]
        for (t, _) in buttons { a.addButton(withTitle: t) }
        a.showsSuppressionButton = true
        a.suppressionButton?.title = Translations.clean(Translations.str("NEVER_ASK_AGAIN"))
        let i = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let r = i >= 0 && i < buttons.count ? buttons[i].1 : .cancel
        // 次回は表示しない: 上書きの確認をやめて、はい (WinSCP の qaNeverAskAgain)
        if a.suppressionButton?.state == .on && r != .cancel {
            Prefs.confirmOverwrite = false
            return .yes
        }
        return r
    }

    private static func Vcl(_ id: String) -> String { Translations.clean(Translations.str("Vcl_Consts_SMsgDlg" + id)) }
}

/// ラベル付きの部品を並べる道具
enum UI {
    static func label(_ s: String, bold: Bool = false, size: CGFloat = 0) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        if bold { l.font = .boldSystemFont(ofSize: size > 0 ? size : NSFont.systemFontSize) }
        else if size > 0 { l.font = .systemFont(ofSize: size) }
        return l
    }

    static func button(_ title: String, _ target: AnyObject?, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject?, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: img, target: target, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    static func checkbox(_ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        return b
    }

    static func field(_ s: String = "", width: CGFloat? = nil) -> NSTextField {
        let f = NSTextField(string: s)
        if let w = width { f.widthAnchor.constraint(equalToConstant: w).isActive = true }
        return f
    }

    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 8
        g.columnSpacing = 8
        if g.numberOfColumns > 0 { g.column(at: 0).xPlacement = .trailing }
        g.rowAlignment = .firstBaseline
        return g
    }

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
    static func size(_ n: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(n)) }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()
}
