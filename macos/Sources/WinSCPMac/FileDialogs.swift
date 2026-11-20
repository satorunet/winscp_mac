import AppKit
import ScpCore
import UniformTypeIdentifiers

// ファイル操作のダイアログ。どれも WinSCP の .dfm (配置) と JP.ini (日本語) から組み立てる。
// 実行時に変わる文言は WinSCP と同じ文字列表 (TextsWin1.rc / TextsCore1.rc の訳) から作る

extension Dialogs {
    /// 説明つきのエラー (WinSCP の「説明 + 詳細」と同じ並び)
    static func error(_ message: String, _ e: Error) {
        if let r = e as? RemoteError, r.isCancelled { return }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = e.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }

    /// VCL の MessageDlg のボタンの文言 ("はい(&Y)" → "はい")
    static func vcl(_ id: String) -> String { Translations.clean(Translations.str("Vcl_Consts_SMsgDlg" + id)) }
}

/// Mac 版で使えない部品: 無効にして、ヒントで知らせる
func disableUnsupported(_ v: NSView?) {
    guard let v = v else { return }
    if let c = v as? NSControl { c.isEnabled = false }
    v.toolTip = WinSCPMenu.notSupported
}

// MARK: - コピー / 移動 (Copy.dfm)

enum CopyDialog {
    /// 転送先を聞く。OK なら転送先のディレクトリ、キャンセルなら nil
    static func run(upload: Bool, move: Bool, names: [String], target: String, dragDrop: Bool, parent: NSWindow?) -> String? {
        guard let form = DFMForm("Copy.dfm") else { return target }
        // 題名と絵 (Copy.cpp の AdjustTransferControls)
        let caption = upload ? (move ? "COPY_MOVE_TOREMOTE_CAPTION" : "COPY_COPY_TOREMOTE_CAPTION")
                             : (move ? "COPY_MOVE_TOLOCAL_CAPTION" : "COPY_COPY_TOLOCAL_CAPTION")
        let image = upload ? (move ? "Upload File Remove Original" : "Upload File") : (move ? "Download File Remove Original" : "Download File")
        (form["Image"] as? NSImageView)?.image = WinSCPImages.dialog(image)
        // 「アップロード: 2 個のファイル → リモート ディレクトリ (オリジナルを削除):」
        let transferStr = Translations.str(upload ? "COPY_COPY_TOREMOTE" : "COPY_COPY_TOLOCAL")
        let directionStr = Translations.str(upload ? "COPY_TOREMOTE" : "COPY_TOLOCAL")
        let label: String
        if names.count == 1 {
            label = Translations.fmt(move ? "MOVE_FILE" : "COPY_FILE", transferStr, names[0], directionStr)
        } else {
            label = Translations.fmt(move ? "MOVE_FILES" : "COPY_FILES", transferStr, names.count, directionStr)
        }
        if let l = form.label("DirectoryLabel") {
            l.stringValue = label
            l.frame.size.width = form.view.frame.width - l.frame.minX - 8
            l.lineBreakMode = .byTruncatingMiddle
        }
        // 転送先の欄: アップロードはリモートの欄、ダウンロードはローカルの欄と参照ボタン
        let edit = form.combo(upload ? "RemoteDirectoryEdit" : "LocalDirectoryEdit")
        form.setVisible("RemoteDirectoryEdit", upload)
        form.setVisible("LocalDirectoryEdit", !upload)
        form.setVisible("LocalDirectoryBrowseButton", !upload)
        var dir = target
        if !dir.hasSuffix("/") { dir += "/" }
        edit?.stringValue = dir + "*.*"
        let historyKey = upload ? "WinSCPCopyRemoteHistory" : "WinSCPCopyLocalHistory"
        let history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        edit?.addItems(withObjectValues: history)
        if !upload, let b = form.button("LocalDirectoryBrowseButton") {
            let t = ClosureTarget {
                let o = NSOpenPanel()
                o.canChooseDirectories = true
                o.canChooseFiles = false
                o.canCreateDirectories = true
                o.directoryURL = URL(fileURLWithPath: target)
                if o.runModal() == .OK, let u = o.url { edit?.stringValue = u.path + "/*.*" }
            }
            b.target = t
            b.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(b, "closure", t, .OBJC_ASSOCIATION_RETAIN)
        }
        // 転送設定の要約 (TCopyParamType::GetInfoStr): 転送モードと、既定と違うもの
        func info() -> String {
            var s = Translations.format(Translations.part("COPY_INFO_TRANSFER_TYPE2", 1), [Translations.part("COPY_INFO_TRANSFER_TYPE2", 2)])
            if !Prefs.preserveTime { s += "; " + Translations.str("COPY_INFO_DONT_PRESERVE_TIME") }
            return s
        }
        if let l = form.label("CopyParamLabel") { l.stringValue = info(); l.toolTip = info() }
        // バックグラウンドでの転送 (転送キュー): Mac 版にはない
        if let q = form.button("QueueCheck2") {
            q.title = Translations.clean(Translations.fmt("COPY_QUEUE", Translations.clean(Translations.str("COPY_BACKGROUND"))))
            q.frame.size.width = 360
            q.state = .off
            disableUnsupported(q)
        }
        // 転送設定… (CopyParamCustom.dfm)
        if let b = form.button("TransferSettingsButton") {
            let t = ClosureTarget {
                if TransferSettingsDialog.run() { form.label("CopyParamLabel")?.stringValue = info() }
            }
            b.target = t
            b.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(b, "closure", t, .OBJC_ASSOCIATION_RETAIN)
        }
        // F5 のヒント (コマンダーで初めて F5 で転送したとき)
        let hintKey = "WinSCPCopyShortCutHintShown"
        let viaF5 = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) == NSF5FunctionKey } == true
        if !viaF5 || UserDefaults.standard.bool(forKey: hintKey) {
            form.setVisible("ShortCutHintPanel", false)
            form.view.setFrameSize(NSSize(width: form.view.frame.width, height: form.view.frame.height - 38))
        } else {
            UserDefaults.standard.set(true, forKey: hintKey)
            (form["ShortCutHintPanel"])?.wantsLayer = true
            (form["ShortCutHintPanel"])?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        }
        // 「このダイアログを二度と表示しない」 (WinSCP の ConfirmTransferring)
        form.button("NeverShowAgainCheck")?.state = .off
        guard form.runModal(title: Translations.str(caption), parent: parent) == "OkButton" else { return nil }
        if form.button("NeverShowAgainCheck")?.state == .on { Prefs.showCopyDialog = false }
        // 転送先: 最後の要素はファイル マスク
        var t = (edit?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return target }
        var mask = ""
        if !t.hasSuffix("/") {
            mask = (t as NSString).lastPathComponent
            t = (t as NSString).deletingLastPathComponent
        }
        if !upload { t = (t as NSString).expandingTildeInPath }
        if t.isEmpty { t = upload ? "/" : target }
        if !["", "*", "*.*"].contains(mask) {
            Dialogs.message(Translations.fmt("COPY_INFO_FILE_MASK", mask), WinSCPMenu.notSupported)
        }
        let h = [t] + history.filter { $0 != t }
        UserDefaults.standard.set(Array(h.prefix(10)), forKey: historyKey)
        return t
    }
}

/// 転送設定 (CopyParamCustom.dfm + CopyParams.dfm)。Mac 版で変えられるのはタイムスタンプの保持だけ
enum TransferSettingsDialog {
    static func run() -> Bool {
        guard let form = DFMForm("CopyParamCustom.dfm") else { return false }
        let keep = ["PreserveTimeCheck", "OkButton", "CancelButton", "HelpButton"]
        for (n, v) in form.views where !keep.contains(n) {
            if v is NSButton || v is NSComboBox || v is NSPopUpButton || v is NSTextField && (v as? NSTextField)?.isEditable == true {
                disableUnsupported(v)
            }
            if let b = v as? BrowseField { b.field.isEnabled = false; b.button.isEnabled = false }
        }
        form.button("PreserveTimeCheck")?.state = Prefs.preserveTime ? .on : .off
        form.button("TMBinaryButton")?.state = .on
        form.button("CCNoChangeButton")?.state = .on
        form.button("CommonCalculateSizeCheck")?.state = .on
        form.combo("SpeedCombo")?.stringValue = Translations.str("SPEED_UNLIMITED")
        form.combo("IncludeFileMaskCombo")?.stringValue = ""
        guard form.runModal(parent: nil) == "OkButton" else { return false }
        Prefs.preserveTime = form.button("PreserveTimeCheck")?.state == .on
        return true
    }
}

// MARK: - パーミッション (Rights.dfm のフレーム)

/// RightsFrame のチェックボックスと 8 進数の欄をつなぐ
final class RightsFrame {
    let form: DFMForm
    /// (チェックボックスの名前, ビット)
    static let bits: [(String, UInt32)] = [
        ("OwnerReadCheck", 0o400), ("OwnerWriteCheck", 0o200), ("OwnerExecuteCheck", 0o100),
        ("GroupReadCheck", 0o040), ("GroupWriteCheck", 0o020), ("GroupExecuteCheck", 0o010),
        ("OthersReadCheck", 0o004), ("OthersWriteCheck", 0o002), ("OthersExecuteCheck", 0o001),
        ("SetUidCheck", 0o4000), ("SetGIDCheck", 0o2000), ("StickyBitCheck", 0o1000),
    ]
    private var targets: [ClosureTarget] = []
    var onChange: (() -> Void)?

    init(form: DFMForm) {
        self.form = form
        form.setVisible("CloseButton", false)
        let sync = ClosureTarget { [unowned self] in self.updateOctal(); self.onChange?() }
        targets.append(sync)
        for (n, _) in RightsFrame.bits {
            form.button(n)?.target = sync
            form.button(n)?.action = #selector(ClosureTarget.fire)
        }
        // 所有者 / グループ / その他のボタン: その行をまとめて切り替える
        for (btn, row) in [("OwnerButton", 0), ("GroupButton", 1), ("OthersButton", 2)] {
            let t = ClosureTarget { [unowned self] in
                let boxes = (0..<3).compactMap { self.form.button(RightsFrame.bits[row * 3 + $0].0) }
                let on = !boxes.allSatisfy { $0.state == .on }
                boxes.forEach { $0.state = on ? .on : .off }
                self.updateOctal()
                self.onChange?()
            }
            targets.append(t)
            form.button(btn)?.target = t
            form.button(btn)?.action = #selector(ClosureTarget.fire)
            // TSpeedButton (Flat): 枠のない、文字だけのボタン
            form.button(btn)?.bezelStyle = .recessed
            form.button(btn)?.showsBorderOnlyWhileMouseInside = true
            form.button(btn)?.alignment = .left
            if let b = form.button(btn) { b.frame.size.width = max(b.frame.width, ceil(b.intrinsicContentSize.width)) }
        }
        let fromOctal = ClosureTarget { [unowned self] in
            guard let s = self.form.field("OctalEdit")?.stringValue, let m = UInt32(s, radix: 8) else { return }
            self.set(mode: m)
        }
        targets.append(fromOctal)
        form.field("OctalEdit")?.target = fromOctal
        form.field("OctalEdit")?.action = #selector(ClosureTarget.fire)
    }

    /// 複数のファイル: 違うビットは「そのまま」(グレー)
    func set(modes: [UInt32]) {
        for (n, bit) in RightsFrame.bits {
            guard let b = form.button(n) else { continue }
            let ons = modes.filter { $0 & bit != 0 }.count
            b.allowsMixedState = ons != 0 && ons != modes.count
            b.state = ons == 0 ? .off : (ons == modes.count ? .on : .mixed)
        }
        updateOctal()
    }
    func set(mode: UInt32) { set(modes: [mode]) }

    private func updateOctal() {
        let anyMixed = RightsFrame.bits.contains { form.button($0.0)?.state == .mixed }
        form.field("OctalEdit")?.stringValue = anyMixed ? "" : String(format: "%04o", change.set)
    }

    /// 付けるビットと外すビット (グレーはどちらでもない)
    var change: (set: UInt32, clear: UInt32) {
        var s: UInt32 = 0, c: UInt32 = 0
        for (n, bit) in RightsFrame.bits {
            switch form.button(n)?.state {
            case .on?: s |= bit
            case .off?: c |= bit
            default: break
            }
        }
        // 8 進数の欄を直接書き換えた場合
        if let t = form.field("OctalEdit")?.stringValue, !t.isEmpty, let m = UInt32(t, radix: 8), m != s {
            return (m, 0o7777 & ~m)
        }
        return (s, c)
    }

    func setEnabled(_ e: Bool) {
        for n in RightsFrame.bits.map(\.0) + ["OwnerButton", "GroupButton", "OthersButton", "OctalEdit", "DirectoriesXCheck"] {
            form.setEnabled(n, e)
        }
    }
}

/// パーミッションの変更 (付ける・外す・ディレクトリに X)
struct RightsChange {
    var set: UInt32
    var clear: UInt32
    var addXToDirectories: Bool
    func apply(_ old: UInt32, isDirectory: Bool) -> UInt32 {
        var m = (old & ~clear) | set
        if isDirectory && addXToDirectories {
            // 読める人は入れる (WinSCP の AddXToDirectories)
            if m & 0o400 != 0 { m |= 0o100 }
            if m & 0o040 != 0 { m |= 0o010 }
            if m & 0o004 != 0 { m |= 0o001 }
        }
        return m & 0o7777
    }
}

// MARK: - フォルダの作成 (CreateDirectory.dfm)

enum CreateDirectoryDialog {
    static func run(remote: Bool, parent: NSWindow?) -> (name: String, mode: UInt32?)? {
        guard let form = DFMForm("CreateDirectory.dfm") else { return nil }
        let d = UserDefaults.standard
        form.field("DirectoryEdit")?.stringValue = Translations.str("NEW_FOLDER")
        var rights: RightsFrame?
        if !remote {
            // ローカル: 属性の枠を出さない (CreateDirectory.cpp と同じく、その分だけ縮める)
            form.setVisible("AttributesGroup", false)
            let h = CGFloat(form.object("AttributesGroup")?.int("Height") ?? 0)
            form.view.setFrameSize(NSSize(width: form.view.frame.width, height: form.view.frame.height - h))
        } else {
            let r = RightsFrame(form: form)
            r.set(mode: UInt32(d.object(forKey: "WinSCPNewDirRights") as? Int ?? 0o755))
            form.setVisible("DirectoriesXCheck", false)
            let save = d.bool(forKey: "WinSCPNewDirSave")
            form.button("SetRightsCheck")?.state = save && d.bool(forKey: "WinSCPNewDirSetRights") ? .on : .off
            form.button("SaveSettingsCheck")?.state = save ? .on : .off
            rights = r
        }
        func update() {
            let name = form.field("DirectoryEdit")?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            form.button("OKBtn")?.isEnabled = !name.isEmpty
            rights?.setEnabled(form.button("SetRightsCheck")?.state == .on)
        }
        form.onChange(["SetRightsCheck"], update)
        let tok = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: form.field("DirectoryEdit"), queue: .main) { _ in update() }
        update()
        let result = form.runModal(parent: parent)
        NotificationCenter.default.removeObserver(tok)
        guard result == "OKBtn" else { return nil }
        let name = form.field("DirectoryEdit")?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        guard let r = rights else { return (name, nil) }
        let setRights = form.button("SetRightsCheck")?.state == .on
        if form.button("SaveSettingsCheck")?.state == .on {
            d.set(true, forKey: "WinSCPNewDirSave")
            d.set(setRights, forKey: "WinSCPNewDirSetRights")
            d.set(Int(r.change.set), forKey: "WinSCPNewDirRights")
        } else {
            d.set(false, forKey: "WinSCPNewDirSave")
        }
        return (name, setRights ? r.change.set : nil)
    }
}

// MARK: - プロパティ (Properties.dfm)

enum PropertiesDialog {
    static func run(entries: [FileEntry], dir: String, remote: Bool, parent: NSWindow?, apply: @escaping (RightsChange, Bool) -> Void) {
        guard let form = DFMForm("Properties.dfm") else { return }
        let multiple = entries.count > 1
        let e = entries[0]
        let dirs = entries.filter(\.isDirectory).count
        let nf = FilePanel.numberFormatter
        // 題名 (PROPERTIES_FILE_CAPTION / PROPERTIES_FILES_CAPTION)
        let title = multiple ? Translations.fmt("PROPERTIES_FILES_CAPTION", e.name) : Translations.fmt("PROPERTIES_FILE_CAPTION", e.name)
        // チェックサム・タグのタブは出さない (Mac 版にはない)
        if let tv = form.tabView("PageControl") {
            for n in ["ChecksumSheet", "TagsSheet"] {
                if let i = tv.tabViewItems.first(where: { ($0.identifier as? String) == n }) { tv.removeTabViewItem(i) }
            }
        }
        // 絵
        let icon: NSImage?
        if multiple { icon = WinSCPImages.dialog("Multiple Files") }
        else if !remote { icon = NSWorkspace.shared.icon(forFile: (dir as NSString).appendingPathComponent(e.name)) }
        else if e.isDirectory { icon = NSImage(named: NSImage.folderName) }
        else { icon = NSWorkspace.shared.icon(for: UTTypeHelper.type(forName: e.name)) }
        icon?.size = NSSize(width: 32, height: 32)
        (form["FileIconImage"] as? NSImageView)?.image = icon

        // ファイル名 / 「n 個のファイル, m 個のフォルダ」 (LoadStats)
        func filesStr(files: Int, dirs: Int) -> String {
            var s = ""
            if files > 0 { s = Translations.fmt(files == 1 ? "PROPERTIES_FILE" : "PROPERTIES_FILES", files); if dirs > 0 { s += ", " } }
            if dirs > 0 { s += Translations.fmt(dirs == 1 ? "PROPERTIES_DIRECTORY" : "PROPERTIES_DIRECTORIES", dirs) }
            return s
        }
        func sizeStr(_ n: UInt64) -> String {
            // WinSCP: FormatBytes と、それが丸めた値なら正確なバイト数も
            let a = UI.size(n)
            let b = UI.byteFormatter.string(fromByteCount: 0).replacingOccurrences(of: "0", with: nf.string(from: NSNumber(value: n)) ?? "\(n)")
            return n < 1000 ? a : "\(a) (\(b))"
        }
        form.field("FileLabel")?.stringValue = multiple ? filesStr(files: entries.count - dirs, dirs: dirs) : e.name
        form.field("LocationLabel")?.stringValue = dir
        form.field("LocationLabel")?.lineBreakMode = .byTruncatingHead
        let fileSize = entries.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
        form.field("SizeLabel")?.stringValue = dirs > 0 ? Translations.str("PROPERTIES_UNKNOWN_SIZE") : sizeStr(fileSize)
        // リンク先
        let link = !multiple && e.isSymlink
        form.setVisible("LinksToLabelLabel", link)
        form.setVisible("LinksToLabel", link)
        form.field("LinksToLabel")?.stringValue = e.linkTarget ?? ""
        // 所有者・グループ: Mac 版では変えられないので表示だけ (WinSCP の View の欄)
        let owners = Set(entries.map(\.owner)), groups = Set(entries.map(\.group))
        form.setVisible("OwnerComboBox", false)
        form.setVisible("GroupComboBox", false)
        let hasOwner = !(owners.first ?? "").isEmpty, hasGroup = !(groups.first ?? "").isEmpty
        form.setVisible("OwnerView", hasOwner); form.setVisible("OwnerLabel", hasOwner)
        form.setVisible("GroupView", hasGroup); form.setVisible("GroupLabel", hasGroup)
        form.field("OwnerView")?.stringValue = owners.count == 1 ? owners.first! : ""
        form.field("GroupView")?.stringValue = groups.count == 1 ? groups.first! : ""
        // パーミッション
        let modes = entries.compactMap(\.permissions)
        let hasRights = modes.count == entries.count
        let rights = RightsFrame(form: form)
        form.setVisible("RightsFrame", hasRights)
        form.setVisible("RightsLabel", hasRights)
        if hasRights { rights.set(modes: modes) }
        form.setVisible("DirectoriesXCheck", dirs > 0)
        form.setVisible("GroupOwnerRightsBevel", hasOwner || hasGroup || hasRights)
        // 再帰的に設定
        form.setVisible("RecursiveCheck2", hasRights && dirs > 0)
        form.setVisible("RecursiveBevel", hasRights)
        // 計算: ディレクトリの大きさ
        form.setVisible("CalculateSizeButton", dirs > 0)
        if let b = form.button("CalculateSizeButton") {
            let t = ClosureTarget {
                b.isEnabled = false
                let paths = entries.map { remote ? RemotePath.join(dir, $0.name) : (dir as NSString).appendingPathComponent($0.name) }
                let session = (parent?.windowController as? CommanderWindowController)?.session
                DispatchQueue.global().async {
                    var total: UInt64 = 0, nFiles = 0, nDirs = 0
                    if remote, let s = session {
                        func walk(_ p: String) {
                            for c in (try? s.sync({ try $0.list(p) })) ?? [] {
                                if c.isDirectory && !c.isSymlink { nDirs += 1; walk(RemotePath.join(p, c.name)) } else { nFiles += 1; total += c.size }
                            }
                        }
                        for (i, p) in paths.enumerated() {
                            if entries[i].isDirectory { nDirs += 1; walk(p) } else { nFiles += 1; total += entries[i].size }
                        }
                    } else {
                        let fm = FileManager.default
                        for (i, p) in paths.enumerated() {
                            if !entries[i].isDirectory { nFiles += 1; total += entries[i].size; continue }
                            nDirs += 1
                            let en = fm.enumerator(atPath: p)
                            while let r = en?.nextObject() as? String {
                                let a = en?.fileAttributes
                                if (a?[.type] as? FileAttributeType) == .typeDirectory { nDirs += 1 }
                                else { nFiles += 1; total += (a?[.size] as? NSNumber)?.uint64Value ?? 0 }
                                _ = r
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        form.field("SizeLabel")?.stringValue = sizeStr(total)
                        form.field("FileLabel")?.stringValue = filesStr(files: nFiles, dirs: nDirs)
                    }
                }
            }
            b.target = t
            b.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(b, "closure", t, .OBJC_ASSOCIATION_RETAIN)
        }
        if !hasRights {
            form.button("OkButton")?.isEnabled = false
        }
        guard form.runModal(title: title, parent: parent) == "OkButton", hasRights else { return }
        let ch = rights.change
        let change = RightsChange(set: ch.set, clear: ch.clear, addXToDirectories: form.button("DirectoriesXCheck")?.state == .on)
        let recursive = form.button("RecursiveCheck2")?.state == .on
        let changed = recursive || change.addXToDirectories || entries.contains { change.apply($0.permissions ?? 0, isDirectory: $0.isDirectory) != ($0.permissions ?? 0) }
        if changed { apply(change, recursive) }
    }
}

/// 拡張子から種類 (アイコン用)
enum UTTypeHelper {
    static func type(forName n: String) -> UTType {
        UTType(filenameExtension: (n as NSString).pathExtension) ?? .data
    }
}
