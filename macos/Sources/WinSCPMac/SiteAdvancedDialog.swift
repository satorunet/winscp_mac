import AppKit
import ScpCore

/// WinSCP の「高度なサイトの設定」(SiteAdvanced.dfm / SiteAdvanced.cpp)。
/// 値は Site.settings に WinSCP.ini のセッションのキー名のまま入れる (既定値と同じものはキーを消す: WinSCP と同じ)。
enum SiteAdvancedDialog {
    /// ダイアログを出す。OK なら site を書き換えて true
    static func run(_ site: inout Site, parent: NSWindow?) -> Bool {
        guard let c = SiteAdvancedController(site: site) else { return false }
        guard c.runModal(parent: parent) else { return false }
        site = c.save()
        return true
    }

    /// 画面の確認用 (WINSCPMAC_RENDER): "SiteAdvanced:<sftp|scp|ftp|ftps>:<シート名>"
    static func renderForTest(_ spec: String) -> NSView? {
        let parts = spec.split(separator: ":").map(String.init)
        var s = Site()
        s.host = "example.com"
        switch parts.count > 1 ? parts[1] : "sftp" {
        case "scp": s.proto = .scp
        case "ftp": s.proto = .ftp; s.port = 21
        case "ftps": s.proto = .ftp; s.port = 21; s.ftpSecurity = .explicitTLS
        default: s.proto = .sftp
        }
        guard let c = SiteAdvancedController(site: s) else { return nil }
        rendered.append(c)
        if parts.count > 2 { c.showPage(parts[2]) }
        // 何も変えずに保存したら、キーは増えない (既定値は書かない)
        SelfTest.log.append("\(spec): \(c.treeDescription) / saved keys \(c.save().settings.keys.sorted())")
        return c.form.view
    }
    private static var rendered: [SiteAdvancedController] = []
}

/// Mac 版では使えない設定のツールチップ
private let unsupportedTip = "Mac 版では未対応です"

final class SiteAdvancedController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let form: DFMForm
    private var site: Site
    private var data: WinSCPSessionData
    private let tr = Translations.shared

    /// ナビゲーションの木の項目
    final class Node: NSObject {
        let sheet: String
        var label: String
        var children: [Node] = []
        init(_ sheet: String, _ label: String) { self.sheet = sheet; self.label = label }
    }
    private var nodes: [Node] = []
    private var outline: NavigationOutlineView!
    private var activeSheet = "EnvironmentSheet"

    /// コントロールごとの Enabled (VCL と同じく、親が無効なら子も無効に見える)
    private var enabled: [String: Bool] = [:]
    /// TTabSheet の Enabled (無効なシートは木に出ない)
    private var sheetEnabled: [String: Bool] = [:]
    /// .dfm のツールチップ (未対応の表示から戻すため)
    private var originalTips: [String: String] = [:]
    private var cipherOrder: [String] = []
    private var kexOrder: [String] = []
    private var color = 0
    private var noUpdate = 0
    private var textObserver: NSObjectProtocol?

    // MARK: - 定数 (WinSCP の並び)

    /// シートの並び (PageControl の順)
    private var sheets: [DFMObject] {
        form.object("PageControl")?.children.filter { $0.className == "TTabSheet" } ?? []
    }

    /// Mac 版では使えないもの (無効にしてツールチップを出す)
    private static let unsupported: Set<String> = [
        // 環境
        "EOLTypeLabel", "EOLTypeCombo", "UtfLabel", "UtfCombo", "TrimVMSVersionsCheck", "DSTModeGroup", "PuttyGroup",
        // ディレクトリ
        "CacheDirectoriesCheck", "CacheDirectoryChangesCheck", "PreserveDirectoryChangesCheck",
        "ResolveSymlinksCheck", "FollowDirectorySymlinksCheck",
        // ごみ箱・暗号化
        "RecycleBinGroup", "EncryptFilesCheck", "EncryptFilesGroup",
        // SFTP
        "SFTPBugsGroupBox", "Label34", "SFTPMaxVersionCombo", "Label5", "SFTPRealPathCombo", "UsePosixRenameCheck",
        // シェル
        "ShellGroup", "OtherShellOptionsGroup", "IgnoreLsWarningsCheck",
        // FTP
        "VMSAllRevisionsCheck",
        // 接続
        "BufferSizeCheck",
        // プロキシ
        "Label17", "ProxyDNSCombo", "ProxyLocalhostCheck",
        // トンネル
        "TunnelOptionsGroup",
        // TLS
        "TlsAuthenticationGroup",
        // SSH
        "Ssh2LegacyDESCheck", "AuthGSSAPIKEXCheck", "SshNoUserAuthCheck", "PrivateKeyToolsButton", "BugsGroupBox",
        // S3 / WebDAV (このアプリでは使わないプロトコル)
        "S3Group", "S3AuthenticationGroup", "WebdavGroup",
    ]
    /// その時の状態で未対応になるもの (SSH の SOCKS/HTTP プロキシの認証など)
    private var dynamicUnsupported: Set<String> = []

    private var proto: FileProtocol { site.proto }
    private var sshProto: Bool { proto != .ftp }
    private var sftpProto: Bool { proto == .sftp }
    private var scpProto: Bool { proto == .scp }
    private var ftpProto: Bool { proto == .ftp }
    private var sslProto: Bool { ftpProto && site.ftpSecurity != .none }

    // MARK: - 作る

    init?(site: Site) {
        guard let f = DFMForm("SiteAdvanced.dfm") else { return nil }
        form = f
        self.site = site
        data = WinSCPSessionData(site.settings)
        super.init()
        for (name, v) in allViews() where v.toolTip != nil { originalTips[name] = v.toolTip }
        initControls()
        load()
        updateControls()
        showPage("EnvironmentSheet")
    }

    deinit { if let o = textObserver { NotificationCenter.default.removeObserver(o) } }

    private func allViews() -> [(String, NSView)] {
        var out: [(String, NSView)] = []
        func walk(_ o: DFMObject) {
            if let v = form[o.name] { out.append((o.name, v)) }
            o.children.forEach(walk)
        }
        walk(form.root)
        return out
    }

    private func t(_ section: String, _ key: String, _ def: String) -> String {
        tr.get(section, key).map { Translations.clean($0).replacingOccurrences(of: "\\n", with: "\n") } ?? def
    }
    private var autoSwitchItems: [String] {
        [t("TextsWin1.rc", "AUTO_SWITCH_AUTO", "Auto"), t("TextsWin1.rc", "AUTO_SWITCH_OFF", "Off"), t("TextsWin1.rc", "AUTO_SWITCH_ON", "On")]
    }

    private func initControls() {
        // 自動/オフ/オン の選択肢 (ComboAutoSwitchInitialize)
        for n in ["UtfCombo", "BugHMAC2Combo", "BugDeriveKey2Combo", "BugRSAPad2Combo", "BugPKSessID2Combo", "BugRekey2Combo",
                  "BugMaxPkt2Combo", "BugIgnore2Combo", "BugWinAdjCombo", "SFTPRealPathCombo", "SFTPBugSymlinkCombo",
                  "SFTPBugSignedTSCombo", "FtpListAllCombo", "FtpUseMlsdCombo", "FtpForcePasvIpCombo", "FtpHostCombo"] {
            guard let p = form.popup(n) else { continue }
            p.removeAllItems()
            p.addItems(withTitles: autoSwitchItems)
        }
        // トンネルのローカル ポート: 自動選択 + 50000-50099 (WinSCP の TunnelLocalPortNumberLow/High)
        if let c = form.combo("TunnelLocalPortNumberEdit") {
            let first = (c.objectValues.first as? String) ?? "Autoselect"
            c.removeAllItems()
            c.addItems(withObjectValues: [first] + (50000...50099).map(String.init))
        }
        // パターンのヒント
        let hint = t("TextsWin1.rc", "LOGIN_PROXY_COMMAND_PATTERNS_HINT", "Patterns")
        for n in ["ProxyTelnetCommandHintText", "ProxyLocalCommandHintText"] {
            if let l = form.label(n) { l.toolTip = hint; l.textColor = .linkColor; originalTips[n] = hint }
        }
        // FTP のプロキシ: Mac 版は SOCKS4/SOCKS5 だけ
        if let p = form.popup("FtpProxyMethodCombo") {
            p.autoenablesItems = false
            for (i, item) in p.itemArray.enumerated() where i >= 3 {
                item.isEnabled = false
                item.toolTip = unsupportedTip
            }
        }
        form.setVisible("NeonProxyMethodCombo", false)
        // 暗号鍵の欄は 1 つだけ見せる
        form.setVisible("EncryptKeyVisibleEdit", false)

        // 木 (NavigationTree): 三角を出さない NSOutlineView に差し替える
        if let sv = form["NavigationTree"] as? NSScrollView {
            let ov = NavigationOutlineView()
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
            col.resizingMask = .autoresizingMask
            ov.addTableColumn(col)
            ov.outlineTableColumn = col
            ov.headerView = nil
            ov.rowHeight = 18
            ov.indentationPerLevel = 16
            ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            ov.dataSource = self
            ov.delegate = self
            sv.documentView = ov
            col.width = sv.contentSize.width
            outline = ov
        }

        // 一覧の上へ/下へ
        hook("CipherUpButton") { [weak self] in self?.moveAlg(cipher: true, by: -1) }
        hook("CipherDownButton") { [weak self] in self?.moveAlg(cipher: true, by: 1) }
        hook("KexUpButton") { [weak self] in self?.moveAlg(cipher: false, by: -1) }
        hook("KexDownButton") { [weak self] in self?.moveAlg(cipher: false, by: 1) }
        form.listBox("CipherListBox")?.onSelect = { [weak self] in self?.dataChange() }
        form.listBox("KexListBox")?.onSelect = { [weak self] in self?.dataChange() }
        hook("HelpButton") { [weak self] in self?.help() }
        hook("ColorButton") { [weak self] in self?.colorMenu() }
        hook("ProxyAutodetectButton") { [weak self] in self?.proxyAutodetect() }
        hook("ProxyLocalCommandBrowseButton") { [weak self] in self?.browseLocalProxy() }
        hook("PrivateKeyViewButton") { [weak self] in self?.viewPublicKey() }
        hook("ShowEncryptionKeyCheck") { [weak self] in self?.dataChange() }
        form.onChange(["MinTlsVersionCombo"]) { [weak self] in self?.tlsChanged(min: true) }
        form.onChange(["MaxTlsVersionCombo"]) { [weak self] in self?.tlsChanged(min: false) }

        // 値が変わったら有効/無効を見直す (DataChange)
        let changeNames = allViews().compactMap { name, v -> String? in
            if name == "MinTlsVersionCombo" || name == "MaxTlsVersionCombo" || name == "ShowEncryptionKeyCheck" { return nil }
            switch form.object(name)?.className ?? "" {
            case "TCheckBox", "TRadioButton", "TComboBox", "TUpDownEdit": return name
            default: return nil
            }
        }
        form.onChange(changeNames) { [weak self] in self?.dataChange() }
        textObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let v = n.object as? NSView, v.isDescendant(of: self.form.view) else { return }
            self.dataChange()
        }
        for n in ["LocalDirectoryEdit", "PrivateKeyEdit3", "TunnelPrivateKeyEdit3", "DetachedCertificateEdit"] {
            guard let b = form[n] as? BrowseField else { continue }
            b.directory = n == "LocalDirectoryEdit"
            b.onBrowse = { [weak self, weak b] in
                guard let b = b else { return }
                let o = NSOpenPanel()
                o.canChooseDirectories = b.directory
                o.canChooseFiles = !b.directory
                o.showsHiddenFiles = true
                if !b.stringValue.isEmpty {
                    let u = URL(fileURLWithPath: (b.stringValue as NSString).expandingTildeInPath)
                    o.directoryURL = b.directory ? u : u.deletingLastPathComponent()
                } else if !b.directory {
                    o.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                }
                if o.runModal() == .OK, let u = o.url { b.stringValue = u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                self?.dataChange()
            }
        }
    }

    private var closures: [ClosureTarget] = []
    private func hook(_ name: String, _ f: @escaping () -> Void) {
        guard let b = form.button(name) else { return }
        let t = ClosureTarget(f)
        closures.append(t)
        b.target = t
        b.action = #selector(ClosureTarget.fire)
    }

    // MARK: - 読み込み (LoadSession)

    private func check(_ n: String, _ on: Bool) { form.button(n)?.state = on ? .on : .off }
    private func checked(_ n: String) -> Bool { form.button(n)?.state == .on }
    private func setText(_ n: String, _ s: String) {
        if let b = form[n] as? BrowseField { b.stringValue = s }
        else if let c = form.combo(n) { c.stringValue = s }
        else if let tv = form.textView(n) { tv.string = s }
        else { form.field(n)?.stringValue = s }
    }
    private func text(_ n: String) -> String {
        if let b = form[n] as? BrowseField { return b.stringValue }
        if let c = form.combo(n) { return c.stringValue }
        if let tv = form.textView(n) { return tv.string }
        return form.field(n)?.stringValue ?? ""
    }
    private func select(_ n: String, _ i: Int) {
        guard let p = form.popup(n) else { return }
        p.selectItem(at: max(0, min(i, p.numberOfItems - 1)))
    }
    private func index(_ n: String) -> Int { form.popup(n)?.indexOfSelectedItem ?? 0 }
    private func num(_ n: String) -> Int { form.stepper(n)?.value ?? 0 }
    private func setNum(_ n: String, _ v: Int) { form.stepper(n)?.value = v }
    /// ComboAutoSwitchLoad: 項目の位置 = 2 - 値
    private func loadAutoSwitch(_ n: String, _ v: WinSCPSessionData.AutoSwitch) { select(n, 2 - v.rawValue) }
    private func autoSwitch(_ n: String) -> WinSCPSessionData.AutoSwitch { .init(rawValue: 2 - index(n)) ?? .auto }
    private func comboFirst(_ n: String) -> String { (form.combo(n)?.objectValues.first as? String) ?? "" }
    /// メモ欄 (WinSCP は行を CR/LF でつなぐ)
    private func memoLoad(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\r\n", with: "\n")
        if r.hasSuffix("\n") { r.removeLast() }
        return r
    }
    private func memoSave(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return s.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    private func load() {
        noUpdate += 1
        defer { noUpdate -= 1 }
        let d = data

        // ディレクトリ
        check("SynchronizeBrowsingCheck", d.bool("SynchronizeBrowsing", false))
        setText("LocalDirectoryEdit", site.localDirectory)
        setText("RemoteDirectoryEdit", site.remoteDirectory)
        check("UpdateDirectoriesCheck", d.bool("UpdateDirectories", true))
        check("CacheDirectoriesCheck", d.bool("CacheDirectories", true))
        check("CacheDirectoryChangesCheck", d.bool("CacheDirectoryChanges", true))
        check("PreserveDirectoryChangesCheck", d.bool("PreserveDirectoryChanges", true))
        check("ResolveSymlinksCheck", d.bool("ResolveSymlinks", true))
        check("FollowDirectorySymlinksCheck", d.bool("FollowDirectorySymlinks", false))

        // 環境
        let dst = d.int("ConsiderDST", 1)
        check("DSTModeWinCheck", dst == 0)
        check("DSTModeUnixCheck", dst != 0)
        select("EOLTypeCombo", d.int("EOLType", 0) == 0 ? 0 : 1)
        switch d.autoSwitch("Utf") {
        case .on: select("UtfCombo", 1)
        case .off: select("UtfCombo", 2)
        case .auto: select("UtfCombo", 0)
        }
        let td = d.timeDifferenceMinutes
        setNum("TimeDifferenceEdit", td / 60)
        setNum("TimeDifferenceMinutesEdit", td % 60)
        check("TimeDifferenceAutoCheck", d.timeDifferenceAuto)
        check("TrimVMSVersionsCheck", d.bool("TrimVMSVersions", false))
        check("VMSAllRevisionsCheck", d.bool("VMSAllRevisions", false))
        setText("PuttySettingsEdit", d.string("PuttySettings"))

        // ごみ箱
        check("DeleteToRecycleBinCheck", d.bool("DeleteToRecycleBin", false))
        check("OverwrittenToRecycleBinCheck", d.bool("OverwrittenToRecycleBin", false))
        let rb = d.string("RecycleBinPath")
        setText("RecycleBinPathEdit", rb.isEmpty ? "/tmp" : rb)

        // SFTP
        let srv = d.string("SftpServer")
        setText("SftpServerEdit", srv.isEmpty ? comboFirst("SftpServerEdit") : srv)
        check("AllowScpFallbackCheck", d.int("FSProtocol", 1) == 1)
        check("UsePosixRenameCheck", d.bool("UsePosixRename", false))
        let mv = d.int("SFTPMaxVersion", -1)
        select("SFTPMaxVersionCombo", mv < 0 ? 0 : mv + 1)
        loadAutoSwitch("SFTPRealPathCombo", d.autoSwitch("SFTPRealPath"))
        loadAutoSwitch("SFTPBugSymlinkCombo", d.autoSwitch("SFTPSymlinkBug"))
        loadAutoSwitch("SFTPBugSignedTSCombo", d.autoSwitch("SFTPSignedTSBug"))

        // FTP
        setText("FtpAccountEdit", d.string("FtpAccount"))
        setText("PostLoginCommandsMemo", memoLoad(d.string("PostLoginCommands")))
        loadAutoSwitch("FtpListAllCombo", d.autoSwitch("FtpListAll"))
        loadAutoSwitch("FtpUseMlsdCombo", d.autoSwitch("FtpUseMlsd"))
        loadAutoSwitch("FtpForcePasvIpCombo", d.autoSwitch("FtpForcePasvIp2"))
        loadAutoSwitch("FtpHostCombo", d.autoSwitch("FtpHost"))

        // 認証
        check("SshNoUserAuthCheck", d.bool("SshNoUserAuth", false))
        check("TryAgentCheck2", d.bool("TryAgent", true))
        check("AuthKICheck", d.bool("AuthKI", true))
        check("AuthKIPasswordCheck", d.bool("AuthKIPassword", true))
        check("AuthGSSAPICheck3", d.bool("AuthGSSAPI", true))
        check("GSSAPIFwdTGTCheck", d.bool("GSSAPIFwdTGT", false))
        check("AgentFwdCheck", d.bool("AgentFwd", false))
        setText("PrivateKeyEdit3", site.keyFile)
        setText("DetachedCertificateEdit", d.string("DetachedCertificate"))

        // SSH
        check("Ssh2LegacyDESCheck", d.bool("Ssh2DES", false))
        check("CompressionCheck", d.bool("Compression", false))
        cipherOrder = d.ciphers
        kexOrder = d.kex
        refreshAlgLists()

        // 鍵交換
        check("AuthGSSAPIKEXCheck", d.bool("AuthGSSAPIKEX", false))
        setNum("RekeyTimeEdit", d.int("RekeyTime", 60))
        setText("RekeyDataEdit", d.string("RekeyBytes", "1G"))

        // 接続
        check("FtpPasvModeCheck", site.passive)
        check("BufferSizeCheck", d.int("SendBuf", 262144) > 0 && d.bool("SshSimple", true))
        switch d.int("PingType", 0) {
        case 1: check("PingNullPacketButton", true)
        case 2: check("PingDummyCommandButton", true)
        default: check("PingOffButton", true)
        }
        setNum("PingIntervalSecEdit", d.pingInterval)
        switch d.int("FtpPingType", 2) {
        case 1, 2: check("FtpPingDummyCommandButton", true)
        case 3: check("FtpPingDirectoryListingButton", true)
        default: check("FtpPingOffButton", true)
        }
        setNum("FtpPingIntervalSecEdit", d.int("FtpPingInterval", 30))
        setNum("TimeoutEdit", d.int("Timeout", 15))
        switch d.int("AddressFamily", 0) {
        case 1: check("IPv4Button", true)
        case 2: check("IPv6Button", true)
        default: check("IPAutoButton", true)
        }

        // シェル
        let shell = d.string("Shell")
        setText("ShellEdit", shell.isEmpty ? comboFirst("ShellEdit") : shell)
        let rv = d.string("ReturnVar")
        setText("ReturnVarEdit", rv.isEmpty ? comboFirst("ReturnVarEdit") : rv)
        setText("ListingCommandEdit", d.string("ListingCommand", "ls -la"))
        if let b = form.button("LookupUserGroupsCheck") {
            b.allowsMixedState = true
            switch d.autoSwitch("LookupUserGroups2") { case .on: b.state = .on; case .off: b.state = .off; case .auto: b.state = .mixed }
        }
        check("ClearAliasesCheck", d.bool("ClearAliases", true))
        check("IgnoreLsWarningsCheck", d.bool("IgnoreLsWarnings", true))
        check("Scp1CompatibilityCheck", d.bool("Scp1Compatibility", false))
        check("UnsetNationalVarsCheck", d.bool("UnsetNationalVars", true))
        check("SCPLsFullTimeAutoCheck", d.autoSwitch("SCPLsFullTime") != .off)

        // プロキシ
        let pm = d.proxyMethod
        select("SshProxyMethodCombo", pm)
        let logon = d.int("FtpProxyLogonType", 0)
        select("FtpProxyMethodCombo", logon != 0 ? 3 + logon : (pm <= 3 ? pm : 0))
        select("NeonProxyMethodCombo", pm <= 3 ? pm : 0)
        setText("ProxyHostEdit", d.string("ProxyHost", "proxy"))
        setNum("ProxyPortEdit", d.int("ProxyPort", 80))
        setText("ProxyUsernameEdit", d.string("ProxyUsername"))
        setText("ProxyPasswordEdit", d.proxyPassword)
        setText("ProxyTelnetCommandEdit", d.proxyTelnetCommand)
        setText("ProxyLocalCommandEdit", d.proxyLocalCommand)
        check("ProxyLocalhostCheck", d.bool("ProxyLocalhost", false))
        select("ProxyDNSCombo", 2 - d.proxyDNS.rawValue)

        // バグ (Bug* は 2 - 値 で保存されているので、項目の位置 = 保存されている数)
        for b in ["HMAC2", "DeriveKey2", "RSAPad2", "PKSessID2", "Rekey2", "MaxPkt2", "Ignore2", "WinAdj"] {
            loadAutoSwitch("Bug\(b)Combo", d.bug(b))
        }

        // トンネル
        check("TunnelCheck", d.bool("Tunnel", false))
        setText("TunnelUserNameEdit", d.string("TunnelUserName"))
        setNum("TunnelPortNumberEdit", d.int("TunnelPortNumber", 22))
        setText("TunnelHostNameEdit", d.string("TunnelHostName"))
        setText("TunnelPasswordEdit", d.tunnelPassword)
        setText("TunnelPrivateKeyEdit3", d.string("TunnelPublicKeyFile"))
        let lp = d.int("TunnelLocalPortNumber", 0)
        setText("TunnelLocalPortNumberEdit", lp == 0 ? comboFirst("TunnelLocalPortNumberEdit") : String(lp))

        // TLS/SSL
        func tlsIndex(_ v: Int) -> Int { v <= 10 ? 0 : min(3, v - 10) }
        select("MinTlsVersionCombo", tlsIndex(d.int("MinTlsVersion", 12)))
        select("MaxTlsVersionCombo", tlsIndex(d.int("MaxTlsVersion", 13)))
        check("SslSessionReuseCheck2", d.bool("SslSessionReuse", true))
        setText("TlsCertificateFileEdit", d.string("TlsCertificateFile"))

        // メモ
        setText("NoteMemo", memoLoad(d.string("Note")))

        // 暗号化
        let ek = d.password(plain: "EncryptKeyPlain", encrypted: "EncryptKey", key: site.user + site.host)
        check("EncryptFilesCheck", !ek.isEmpty)
        setText("EncryptKeyPasswordEdit", ek)

        // WebDAV
        check("WebDavLiberalEscapingCheck", d.bool("WebDavLiberalEscaping", false))
        check("WebDavCrossDomainRedirectsCheck", d.bool("WebDavCrossDomainRedirects", false))

        color = d.int("Color", 0)
    }

    // MARK: - 保存 (SaveSession)

    /// 既定値と同じならキーを消す (WinSCP の WRITE_DATA と同じ)
    private func put(_ k: String, _ v: String, _ def: String) { data.values[k] = v == def ? nil : v }
    private func put(_ k: String, _ v: Int, _ def: Int) { put(k, String(v), String(def)) }
    private func put(_ k: String, _ v: Bool, _ def: Bool) { put(k, v ? "1" : "0", def ? "1" : "0") }

    func save() -> Site {
        var s = site
        // SSH
        put("Compression", checked("CompressionCheck"), false)
        put("Cipher", cipherOrder.joined(separator: ","), WinSCPSessionData.defaultCiphers.joined(separator: ","))
        // 鍵交換
        put("KEX", kexOrder.joined(separator: ","), WinSCPSessionData.defaultKex.joined(separator: ","))
        put("RekeyTime", num("RekeyTimeEdit"), 60)
        put("RekeyBytes", text("RekeyDataEdit").trimmingCharacters(in: .whitespaces), "1G")
        // 認証
        put("TryAgent", checked("TryAgentCheck2"), true)
        put("AuthKI", checked("AuthKICheck"), true)
        put("AuthKIPassword", checked("AuthKIPasswordCheck"), true)
        put("AuthGSSAPI", checked("AuthGSSAPICheck3"), true)
        put("GSSAPIFwdTGT", checked("GSSAPIFwdTGTCheck"), false)
        put("AgentFwd", checked("AgentFwdCheck"), false)
        s.keyFile = text("PrivateKeyEdit3")
        put("DetachedCertificate", text("DetachedCertificateEdit"), "")

        // 接続
        s.passive = checked("FtpPasvModeCheck")
        put("FtpPasvMode", s.passive, true)
        put("PingType", checked("PingNullPacketButton") ? 1 : (checked("PingDummyCommandButton") ? 2 : 0), 0)
        let pi = max(0, num("PingIntervalSecEdit"))
        if pi == 30 { data.values["PingInterval"] = nil; data.values["PingIntervalSecs"] = nil } else { data.pingInterval = pi }
        put("FtpPingType", checked("FtpPingDummyCommandButton") ? 2 : (checked("FtpPingDirectoryListingButton") ? 3 : 0), 2)
        put("FtpPingInterval", num("FtpPingIntervalSecEdit"), 30)
        put("Timeout", num("TimeoutEdit"), 15)
        put("AddressFamily", checked("IPv4Button") ? 1 : (checked("IPv6Button") ? 2 : 0), 0)

        // ディレクトリ
        put("SynchronizeBrowsing", checked("SynchronizeBrowsingCheck"), false)
        s.localDirectory = text("LocalDirectoryEdit")
        s.remoteDirectory = text("RemoteDirectoryEdit")
        put("UpdateDirectories", checked("UpdateDirectoriesCheck"), true)

        // 環境 (タイムゾーン補正)
        let minutes = num("TimeDifferenceEdit") * 60 + num("TimeDifferenceMinutesEdit")
        let tdAuto = checked("TimeDifferenceAutoCheck")
        if tdAuto && ftpProto {
            // WinSCP: FTP で自動認識のときは TimeDifference を保存しない
            data.values["TimeDifference"] = nil
        } else if minutes == 0 {
            data.values["TimeDifference"] = nil
        } else {
            data.timeDifferenceMinutes = minutes
        }
        put("TimeDifferenceAuto", tdAuto, true)

        // SCP/シェル
        put("ListingCommand", text("ListingCommandEdit"), "ls -la")
        put("SCPLsFullTime", checked("SCPLsFullTimeAutoCheck") ? "2" : "1", "2")

        // SFTP
        let srv = text("SftpServerEdit")
        put("SftpServer", srv == comboFirst("SftpServerEdit") ? "" : srv, "")
        if proto == .sftp {
            // 1 = SFTP (SCP へのフォールバックあり), 2 = SFTP のみ
            data.values["FSProtocol"] = checked("AllowScpFallbackCheck") ? nil : "2"
        }

        // FTP
        put("FtpAccount", text("FtpAccountEdit"), "")
        put("PostLoginCommands", memoSave(text("PostLoginCommandsMemo")), "")
        put("FtpListAll", autoSwitch("FtpListAllCombo").rawValue, 2)
        put("FtpUseMlsd", autoSwitch("FtpUseMlsdCombo").rawValue, 2)
        put("FtpForcePasvIp2", autoSwitch("FtpForcePasvIpCombo").rawValue, 2)
        put("FtpHost", autoSwitch("FtpHostCombo").rawValue, 2)

        // プロキシ
        let pm = proxyMethod()
        put("ProxyMethod", pm, 0)
        put("FtpProxyLogonType", ftpProxyLogonType(), 0)
        let ph = text("ProxyHostEdit"), pu = text("ProxyUsernameEdit")
        put("ProxyHost", ph, "proxy")
        put("ProxyPort", num("ProxyPortEdit"), 80)
        put("ProxyUsername", pu, "")
        data.setPassword(text("ProxyPasswordEdit"), plain: "ProxyPassword", encrypted: "ProxyPasswordEnc", key: pu + ph)
        if pm == 5 {
            put("ProxyTelnetCommand", text("ProxyLocalCommandEdit"), "")
        } else {
            put("ProxyTelnetCommand", text("ProxyTelnetCommandEdit"), "connect %host %port\\n")
        }

        // トンネル
        put("Tunnel", checked("TunnelCheck"), false)
        let tu = text("TunnelUserNameEdit"), th = text("TunnelHostNameEdit")
        put("TunnelUserName", tu, "")
        put("TunnelPortNumber", num("TunnelPortNumberEdit"), 22)
        put("TunnelHostName", th, "")
        data.setPassword(text("TunnelPasswordEdit"), plain: "TunnelPasswordPlain", encrypted: "TunnelPassword", key: tu + th)
        put("TunnelPublicKeyFile", text("TunnelPrivateKeyEdit3"), "")

        // TLS/SSL
        put("MinTlsVersion", 10 + index("MinTlsVersionCombo"), 12)
        put("MaxTlsVersion", 10 + index("MaxTlsVersionCombo"), 13)
        put("SslSessionReuse", checked("SslSessionReuseCheck2"), true)

        // メモ
        put("Note", memoSave(text("NoteMemo")), "")

        // 色
        put("Color", color, 0)

        s.settings = data.values
        return s
    }

    // MARK: - プロキシの種類

    /// GetProxyMethod
    private func proxyMethod() -> Int {
        if sshProto { return index("SshProxyMethodCombo") }
        let i = index("FtpProxyMethodCombo")
        return i <= 3 ? i : 0
    }
    /// GetFtpProxyLogonType
    private func ftpProxyLogonType() -> Int {
        guard ftpProto else { return 0 }
        let i = index("FtpProxyMethodCombo")
        return i <= 3 ? 0 : i - 3
    }

    // MARK: - 有効/無効 (UpdateControls)

    private func en(_ n: String, _ e: Bool) { enabled[n] = e }
    private func isEn(_ n: String) -> Bool { enabled[n] ?? true }
    private func vis(_ n: String, _ v: Bool) { form.setVisible(n, v) }

    private func dataChange() {
        if noUpdate == 0 { updateControls() }
    }

    private func updateControls() {
        noUpdate += 1
        defer { noUpdate -= 1 }
        dynamicUnsupported = []

        // 接続
        en("FtpPasvModeCheck", ftpProto)
        let fpm = index("FtpProxyMethodCombo")
        if ftpProto && fpm != 0 && fpm <= 3 && !checked("FtpPasvModeCheck") {
            check("FtpPasvModeCheck", true)
            if form.view.window?.isVisible == true {
                Dialogs.message(t("TextsWin1.rc", "FTP_PASV_MODE_REQUIRED", "Passive mode is required for FTP connection via proxy."))
            }
        }
        en("BufferSizeCheck", sshProto || ftpProto)
        vis("PingGroup", !ftpProto)
        en("PingGroup", sshProto)
        en("PingIntervalSecEdit", !checked("PingOffButton"))
        en("PingIntervalLabel", !checked("PingOffButton"))
        vis("FtpPingGroup", ftpProto)
        en("FtpPingIntervalSecEdit", !checked("FtpPingOffButton"))
        en("FtpPingIntervalLabel", !checked("FtpPingOffButton"))
        en("IPvGroup", sshProto || ftpProto)
        en("IPAutoButton", sshProto)

        // SSH/認証
        sheetEnabled["AuthSheet"] = sshProto
        // SshNoUserAuthCheck は Mac 版では無効 (= Enabled でない) なので、認証オプションはいつも有効
        en("AuthenticationGroup", true)
        en("AuthKIPasswordCheck", checked("AuthKICheck"))
        en("AuthenticationParamsGroup", true)
        en("AgentFwdCheck", checked("TryAgentCheck2"))
        let key = text("PrivateKeyEdit3").trimmingCharacters(in: .whitespaces)
        en("PrivateKeyViewButton", !key.isEmpty)
        en("DetachedCertificateEdit", !key.isEmpty)
        en("DetachedCertificateLabel", !key.isEmpty)
        en("GSSAPIFwdTGTCheck", checked("AuthGSSAPICheck3"))

        // SSH
        sheetEnabled["AdvancedSheet"] = sshProto
        let ci = form.listBox("CipherListBox")?.selectedIndex ?? -1
        en("CipherUpButton", ci > 0)
        en("CipherDownButton", ci >= 0 && ci < cipherOrder.count - 1)
        // 鍵交換
        sheetEnabled["KexSheet"] = sshProto
        let ki = form.listBox("KexListBox")?.selectedIndex ?? -1
        en("KexUpButton", ki > 0)
        en("KexDownButton", ki >= 0 && ki < kexOrder.count - 1)
        en("KexReexchangeGroup", index("BugRekey2Combo") != 2)
        // バグ
        sheetEnabled["BugsSheet"] = sshProto

        // プロキシ
        let method = proxyMethod()
        vis("SshProxyMethodCombo", sshProto)
        vis("FtpProxyMethodCombo", ftpProto)
        vis("NeonProxyMethodCombo", false)
        let logon = ftpProxyLogonType()
        let command = method == 5 ? text("ProxyLocalCommandEdit") : text("ProxyTelnetCommandEdit")
        func has(_ p: String) -> Bool { command.range(of: p, options: .caseInsensitive) != nil }
        let hostEn = [1, 2, 3, 4].contains(method) || (method == 5 && has("%proxyhost")) || logon > 0
        en("ProxyHostEdit", hostEn); en("ProxyHostLabel", hostEn)
        let portEn = [1, 2, 3, 4].contains(method) || (method == 5 && has("%proxyport")) || logon > 0
        en("ProxyPortEdit", portEn); en("ProxyPortLabel", portEn)
        let userEn = (method == 1 && sshProto) || method == 2 || method == 3 || ((method == 4 || method == 5) && has("%user"))
            || (logon > 0 && logon != 3 && logon != 5)
        en("ProxyUsernameEdit", userEn); en("ProxyUsernameLabel", userEn)
        let passEn = method == 2 || method == 3 || ((method == 4 || method == 5) && has("%pass"))
            || (logon > 0 && logon != 3 && logon != 5)
        en("ProxyPasswordEdit", passEn); en("ProxyPasswordLabel", passEn)
        // Mac 版: SSH の SOCKS/HTTP プロキシは nc を使うので認証できない。FTP の HTTP プロキシ・ログオン形式も未対応
        if sshProto && (1...3).contains(method) {
            dynamicUnsupported.formUnion(["ProxyUsernameEdit", "ProxyUsernameLabel", "ProxyPasswordEdit", "ProxyPasswordLabel"])
        }
        let proxySettings = method != 0 && sshProto
        vis("ProxySettingsGroup", sshProto)
        en("ProxySettingsGroup", proxySettings)
        en("ProxyTelnetCommandEdit", proxySettings && method == 4)
        en("ProxyTelnetCommandLabel", proxySettings && method == 4)
        en("ProxyTelnetCommandHintText", proxySettings && method == 4)
        let local = method == 5
        for n in ["ProxyLocalCommandEdit", "ProxyLocalCommandLabel", "ProxyLocalCommandBrowseButton", "ProxyLocalCommandHintText"] { vis(n, local) }
        for n in ["ProxyTelnetCommandEdit", "ProxyTelnetCommandLabel", "ProxyTelnetCommandHintText"] { vis(n, !local) }

        // 環境/ディレクトリ
        en("CacheDirectoryChangesCheck", !scpProto || checked("CacheDirectoriesCheck"))
        en("PreserveDirectoryChangesCheck", isEn("CacheDirectoryChangesCheck") && checked("CacheDirectoryChangesCheck"))
        en("ResolveSymlinksCheck", sftpProto || scpProto)
        en("FollowDirectorySymlinksCheck", sftpProto || scpProto || ftpProto)

        // 環境
        en("EOLTypeCombo", sftpProto || scpProto); en("EOLTypeLabel", sftpProto || scpProto)
        en("DSTModeGroup", sftpProto || scpProto)
        en("UtfCombo", true); en("UtfLabel", true)
        let ftpNoMlsd = ftpProto && autoSwitch("FtpUseMlsdCombo") == .off
        en("TimeDifferenceAutoCheck", ftpNoMlsd)
        let tdEn = (ftpNoMlsd && !checked("TimeDifferenceAutoCheck")) || scpProto
        en("TimeDifferenceEdit", tdEn)
        en("TimeDifferenceLabel", tdEn || ftpNoMlsd)
        en("TimeDifferenceHoursLabel", tdEn)
        en("TimeDifferenceMinutesEdit", tdEn)
        en("TimeDifferenceMinutesLabel", tdEn)

        // 環境/ごみ箱
        en("OverwrittenToRecycleBinCheck", sftpProto)
        let rbEn = checked("DeleteToRecycleBinCheck") || (sftpProto && checked("OverwrittenToRecycleBinCheck"))
        en("RecycleBinPathEdit", rbEn); en("RecycleBinPathLabel", rbEn)

        // 環境/SFTP
        sheetEnabled["SftpSheet"] = sftpProto
        let srv = text("SftpServerEdit")
        en("AllowScpFallbackCheck", srv.isEmpty || srv == comboFirst("SftpServerEdit"))

        // 環境/シェル
        sheetEnabled["ScpSheet"] = sshProto
        vis("ScpLsOptionsGroup", scpProto)
        vis("OtherShellOptionsGroup", scpProto)

        // 環境/FTP
        sheetEnabled["FtpSheet"] = ftpProto
        let mlsdOff = autoSwitch("FtpUseMlsdCombo") == .off
        en("FtpListAllCombo", mlsdOff); en("FtpListAllLabel", mlsdOff)
        let pasvIP = checked("FtpPasvModeCheck") && (checked("IPAutoButton") || checked("IPv4Button"))
        en("FtpForcePasvIpCombo", pasvIP); en("FtpForcePasvIpLabel", pasvIP)

        // S3 / WebDAV (このアプリにはないプロトコル)
        sheetEnabled["S3Sheet"] = false
        sheetEnabled["WebDavSheet"] = false

        // トンネル
        sheetEnabled["TunnelSheet"] = sshProto
        let tun = checked("TunnelCheck")
        en("TunnelSessionGroup", tun)
        en("TunnelOptionsGroup", tun)
        en("TunnelAuthenticationParamsGroup", tun)

        // 接続/TLS
        sheetEnabled["SslSheet"] = sslProto
        en("SslSessionReuseCheck2", ftpProto)
        vis("TlsAuthenticationGroup", sslProto)

        // 暗号化
        sheetEnabled["EncryptionSheet"] = sftpProto
        en("EncryptFilesGroup", checked("EncryptFilesCheck"))

        applyEnabled()
        updateNavigationTree()
        updateColorButton()
    }

    /// enabled と未対応の一覧を、画面のコントロールに反映する (親が無効なら子も無効)
    private func applyEnabled() {
        let unsup = SiteAdvancedController.unsupported.union(dynamicUnsupported)
        func walk(_ o: DFMObject, _ parentEn: Bool, _ parentUnsup: Bool) {
            let u = parentUnsup || unsup.contains(o.name)
            let own = enabled[o.name] ?? (o.bool("Enabled") ?? true)
            let eff = parentEn && own && !unsup.contains(o.name)
            if let v = form[o.name], o.className != "TTabSheet" {
                form.setEnabled(o.name, eff)
                setTip(v, u ? unsupportedTip : originalTips[o.name])
            }
            for c in o.children { walk(c, eff, u) }
        }
        walk(form.root, true, false)
        // 「パターン」のリンク風のラベルは、無効なら薄く
        for n in ["ProxyTelnetCommandHintText", "ProxyLocalCommandHintText"] {
            guard let l = form.label(n) else { continue }
            l.textColor = l.isEnabled ? .linkColor : .disabledControlTextColor
        }
    }

    private func setTip(_ v: NSView, _ tip: String?) {
        v.toolTip = tip
        if v is NumberField || v is BrowseField || v is ListBoxView {
            for s in v.subviews { s.toolTip = tip }
        }
    }

    // MARK: - ナビゲーションの木 (UpdateNavigationTree)

    private func sheetLabel(_ o: DFMObject) -> String {
        if o.name == "ScpSheet" {
            return scpProto ? t("TextsWin1.rc", "LOGIN_SCP_SHELL_PAGE", "SCP/Shell") : t("TextsWin1.rc", "LOGIN_SHELL_PAGE", "Shell")
        }
        return form.text(o, "Caption") ?? o.name
    }

    private func updateNavigationTree() {
        var top: [Node] = []
        for s in sheets where sheetEnabled[s.name] ?? true {
            let n = Node(s.name, sheetLabel(s))
            if (s.int("Tag") ?? 0) % 100 == 2, let parent = top.last {
                parent.children.append(n)
            } else {
                top.append(n)
            }
        }
        // 変わっていなければ作り直さない (選択が消えないように)
        func sig(_ ns: [Node]) -> String { ns.map { $0.sheet + "[" + sig($0.children) + "]" + $0.label }.joined(separator: ",") }
        if sig(top) != sig(nodes) {
            nodes = top
            outline?.reloadData()
            outline?.expandItem(nil, expandChildren: true)
        }
        if !allNodes().contains(where: { $0.sheet == activeSheet }) {
            showPage("EnvironmentSheet")
        } else {
            selectNode(activeSheet)
        }
    }

    private func allNodes() -> [Node] { nodes.flatMap { [$0] + $0.children } }
    /// 確認用: 木の項目と選択
    var treeDescription: String {
        nodes.map { n in n.label + (n.children.isEmpty ? "" : "[" + n.children.map(\.label).joined(separator: ",") + "]") }
            .joined(separator: " ") + " / selected row \(outline?.selectedRow ?? -1)"
    }

    private func selectNode(_ sheet: String) {
        guard let ov = outline, let n = allNodes().first(where: { $0.sheet == sheet }) else { return }
        let row = ov.row(forItem: n)
        if row >= 0 && ov.selectedRow != row {
            noUpdate += 1
            ov.selectRowIndexes([row], byExtendingSelection: false)
            noUpdate -= 1
        }
    }

    /// ページを切り替える (ChangePage)
    func showPage(_ sheet: String) {
        activeSheet = sheet
        form.tabView("PageControl")?.selectTabViewItem(withIdentifier: sheet)
        selectNode(sheet)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let l = NSTextField(labelWithString: (item as? Node)?.label ?? "")
        l.font = DFMForm.font
        l.lineBreakMode = .byTruncatingTail
        return l
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard noUpdate == 0, let ov = outline, let n = ov.item(atRow: ov.selectedRow) as? Node else { return }
        showPage(n.sheet)
        updateControls()
    }

    // MARK: - 暗号・鍵交換の一覧

    private static let cipherLabels: [String: (String, String)] = [
        "WARN": ("CIPHER_NAME_WARN", "-- warn below here --"), "3des": ("CIPHER_NAME_3DES", "3DES"),
        "blowfish": ("CIPHER_NAME_BLOWFISH", "Blowfish"), "aes": ("CIPHER_NAME_AES2", "AES"), "des": ("CIPHER_NAME_DES", "DES"),
        "arcfour": ("CIPHER_NAME_ARCFOUR2", "Arcfour"), "chacha20": ("CIPHER_NAME_CHACHA20", "ChaCha20"),
        "aesgcm": ("CIPHER_NAME_AESGCM", "AES-GCM"),
    ]
    private static let kexLabels: [String: (String, String)] = [
        "WARN": ("KEX_NAME_WARN", "-- warn below here --"),
        "dh-group1-sha1": ("KEX_NAME_DHGROUP1_BITS", "Diffie-Hellman group 1 (1024-bit)"),
        "dh-group14-sha1": ("KEX_NAME_DHGROUP14_BITS", "Diffie-Hellman group 14 (2048-bit)"),
        "dh-group15-sha512": ("KEX_NAME_DHGROUP15_BITS", "Diffie-Hellman group 15 (3072-bit)"),
        "dh-group16-sha512": ("KEX_NAME_DHGROUP16_BITS", "Diffie-Hellman group 16 (4096-bit)"),
        "dh-group17-sha512": ("KEX_NAME_DHGROUP17_BITS", "Diffie-Hellman group 17 (6144-bit)"),
        "dh-group18-sha512": ("KEX_NAME_DHGROUP18_BITS", "Diffie-Hellman group 18 (8192-bit)"),
        "dh-gex-sha1": ("KEX_NAME_DHGEX", "Diffie-Hellman group exchange"),
        "rsa": ("KEX_NAME_RSA", "RSA-based key exchange"),
        "ecdh": ("KEX_NAME_ECDH", "ECDH key exchange"),
        "ntru-curve25519": ("KEX_NAME_NTRU_HYBRID", "NTRU Prime / Curve25519 hybrid kex"),
        "mlkem-curve25519": ("KEX_NAME_MLKEM_25519_HYBRID", "ML-KEM / Curve25519 hybrid kex"),
        "mlkem-nist": ("KEX_NAME_MLKEM_NIST_HYBRID", "ML-KEM / NIST ECDH hybrid kex"),
    ]

    private func refreshAlgLists() {
        form.listBox("CipherListBox")?.items = cipherOrder.map { n in
            let l = SiteAdvancedController.cipherLabels[n] ?? (n, n)
            return t("TextsWin1.rc", l.0, l.1)
        }
        form.listBox("KexListBox")?.items = kexOrder.map { n in
            let l = SiteAdvancedController.kexLabels[n] ?? (n, n)
            return t("TextsWin1.rc", l.0, l.1)
        }
    }

    private func moveAlg(cipher: Bool, by delta: Int) {
        guard let lb = form.listBox(cipher ? "CipherListBox" : "KexListBox") else { return }
        let i = lb.selectedIndex, j = i + delta
        var list = cipher ? cipherOrder : kexOrder
        guard i >= 0, j >= 0, j < list.count else { return }
        list.swapAt(i, j)
        if cipher { cipherOrder = list } else { kexOrder = list }
        refreshAlgLists()
        lb.selectedIndex = j
        updateControls()
    }

    // MARK: - そのほかのボタン

    private func tlsChanged(min isMin: Bool) {
        let a = index("MinTlsVersionCombo"), b = index("MaxTlsVersionCombo")
        if isMin && b < a { select("MaxTlsVersionCombo", a) }
        if !isMin && a > b { select("MinTlsVersionCombo", b) }
        dataChange()
    }

    /// ヘルプ: WinSCP の説明のページ (シートごとの HelpKeyword)
    private func help() {
        let kw = form.object(activeSheet)?.str("HelpKeyword") ?? form.root.str("HelpKeyword") ?? "ui_login_advanced"
        if let u = URL(string: "https://winscp.net/eng/docs/\(kw)") { NSWorkspace.shared.open(u) }
    }

    /// プロキシの自動認識 (macOS のネットワーク設定から)
    private func proxyAutodetect() {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return }
        func on(_ k: CFString) -> Bool { (s[k as String] as? Int ?? 0) != 0 }
        var host = "", port = 0, method = 0
        if on(kCFNetworkProxiesSOCKSEnable) {
            host = s[kCFNetworkProxiesSOCKSProxy as String] as? String ?? ""
            port = s[kCFNetworkProxiesSOCKSPort as String] as? Int ?? 1080
            method = 2
        } else if on(kCFNetworkProxiesHTTPSEnable) {
            host = s[kCFNetworkProxiesHTTPSProxy as String] as? String ?? ""
            port = s[kCFNetworkProxiesHTTPSPort as String] as? Int ?? 8080
            method = 3
        } else if on(kCFNetworkProxiesHTTPEnable) {
            host = s[kCFNetworkProxiesHTTPProxy as String] as? String ?? ""
            port = s[kCFNetworkProxiesHTTPPort as String] as? Int ?? 8080
            method = 3
        }
        guard method != 0, !host.isEmpty else {
            Dialogs.message("システムのプロキシ設定が見つかりませんでした")
            return
        }
        if sshProto { select("SshProxyMethodCombo", method) }
        else if method == 2 { select("FtpProxyMethodCombo", method) }
        setText("ProxyHostEdit", host)
        setNum("ProxyPortEdit", port)
        updateControls()
    }

    private func browseLocalProxy() {
        let o = NSOpenPanel()
        o.canChooseFiles = true
        o.canChooseDirectories = false
        o.directoryURL = URL(fileURLWithPath: "/usr/bin")
        if o.runModal() == .OK, let u = o.url {
            setText("ProxyLocalCommandEdit", u.path.contains(" ") ? SSHSession.quote(u.path) : u.path)
            dataChange()
        }
    }

    /// 公開鍵を表示: 鍵.pub があればそれ、無ければ ssh-keygen -y (パスフレーズなし) で作る
    private func viewPublicKey() {
        let key = (text("PrivateKeyEdit3") as NSString).expandingTildeInPath
        var pub = (try? String(contentsOfFile: key + ".pub")) ?? ""
        if pub.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-y", "-P", "", "-f", key]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            if (try? p.run()) != nil {
                pub = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
            }
        }
        pub = pub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pub.isEmpty else {
            Dialogs.message("公開鍵を取り出せませんでした (パスフレーズ付きの鍵か、OpenSSH 形式でない鍵です)")
            return
        }
        let a = NSAlert()
        a.messageText = (key as NSString).lastPathComponent
        a.informativeText = "公開鍵 (OpenSSH の authorized_keys の形式):"
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        tv.string = pub
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "コピー")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pub, forType: .string)
        }
    }

    // MARK: - 色 (WinSCP の TColor: 0x00BBGGRR)

    private static let presetColors: [Int] = [0x8080FF, 0x80C0FF, 0x80FFFF, 0x80FF80, 0xFFFF80, 0xFF8080, 0xFF80C0, 0xC0C0C0]

    private static func nsColor(_ c: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(c & 0xff) / 255, green: CGFloat((c >> 8) & 0xff) / 255, blue: CGFloat((c >> 16) & 0xff) / 255, alpha: 1)
    }
    private static func tColor(_ c: NSColor) -> Int {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        let r = Int((s.redComponent * 255).rounded()), g = Int((s.greenComponent * 255).rounded()), b = Int((s.blueComponent * 255).rounded())
        return r | (g << 8) | (b << 16)
    }
    private static func swatch(_ c: Int) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: false) { r in
            nsColor(c).setFill()
            r.fill()
            NSColor.gray.setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func updateColorButton() {
        guard let b = form.button("ColorButton") else { return }
        if color == 0 {
            b.image = nil
        } else {
            b.image = SiteAdvancedController.swatch(color)
            b.imagePosition = .imageRight
        }
    }

    private func colorMenu() {
        guard let b = form.button("ColorButton") else { return }
        let m = NSMenu()
        let def = NSMenuItem(title: "既定の色", action: #selector(pickColor(_:)), keyEquivalent: "")
        def.target = self
        def.tag = 0
        def.state = color == 0 ? .on : .off
        m.addItem(def)
        m.addItem(.separator())
        for c in SiteAdvancedController.presetColors {
            let it = NSMenuItem(title: "", action: #selector(pickColor(_:)), keyEquivalent: "")
            it.target = self
            it.tag = c
            it.image = SiteAdvancedController.swatch(c)
            it.title = String(format: "#%02X%02X%02X", c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff)
            it.state = color == c ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        let more = NSMenuItem(title: "その他の色…", action: #selector(moreColors(_:)), keyEquivalent: "")
        more.target = self
        m.addItem(more)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc private func pickColor(_ i: NSMenuItem) {
        color = i.tag
        updateColorButton()
    }

    @objc private func moreColors(_ i: NSMenuItem) {
        let p = NSColorPanel.shared
        p.showsAlpha = false
        if color != 0 { p.color = SiteAdvancedController.nsColor(color) }
        p.setTarget(self)
        p.setAction(#selector(colorPanelChanged(_:)))
        p.worksWhenModal = true
        p.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ p: NSColorPanel) {
        color = max(1, SiteAdvancedController.tColor(p.color))
        updateColorButton()
    }

    // MARK: - 表示

    func runModal(parent: NSWindow?) -> Bool {
        let r = form.runModal(parent: parent)
        NSColorPanel.shared.setTarget(nil)
        if NSColorPanel.shared.isVisible { NSColorPanel.shared.orderOut(nil) }
        return r == "OKBtn"
    }
}

/// 三角 (開閉のボタン) を出さない木 (WinSCP の ShowButtons = False)
final class NavigationOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
