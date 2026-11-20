import AppKit
import Security
import ScpCore

/// 保存済みサイト (WinSCP の「サイト」)
struct Site: Codable, Equatable {
    var id = UUID()
    /// "フォルダ/サイト名" ("/" でフォルダ分け)
    var name: String = ""
    var proto: FileProtocol = .sftp
    var ftpSecurity: FTPSecurity = .none
    var host: String = ""
    var port: Int = 22
    var user: String = ""
    var savePassword = false
    var keyFile: String = ""
    var remoteDirectory: String = ""
    var localDirectory: String = ""
    var passive = true
    /// WinSCP の「高度なサイトの設定」の項目 (WinSCP.ini のセッションのキー名 → 値)
    var settings: [String: String] = [:]
    /// パスワード (保存しない。Keychain から読む / ログイン時の入力)
    var password: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, proto, ftpSecurity, host, port, user, savePassword, keyFile, remoteDirectory, localDirectory, passive, settings
    }

    /// WinSCP のキーで設定を読む
    func setting(_ key: String, _ def: String = "") -> String { settings[key] ?? def }
    func setting(_ key: String, _ def: Int) -> Int { settings[key].flatMap { Int($0) } ?? def }
    func setting(_ key: String, _ def: Bool) -> Bool {
        guard let v = settings[key] else { return def }
        return v == "1" || v.lowercased() == "on" || v.lowercased() == "true"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        proto = (try? c.decode(FileProtocol.self, forKey: .proto)) ?? .sftp
        ftpSecurity = (try? c.decode(FTPSecurity.self, forKey: .ftpSecurity)) ?? .none
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 22
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        savePassword = (try? c.decode(Bool.self, forKey: .savePassword)) ?? false
        keyFile = (try? c.decode(String.self, forKey: .keyFile)) ?? ""
        remoteDirectory = (try? c.decode(String.self, forKey: .remoteDirectory)) ?? ""
        localDirectory = (try? c.decode(String.self, forKey: .localDirectory)) ?? ""
        passive = (try? c.decode(Bool.self, forKey: .passive)) ?? true
        settings = (try? c.decode([String: String].self, forKey: .settings)) ?? [:]
    }

    /// 一覧の最後の部分 (フォルダを除いた名前)
    var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }
    var folder: String {
        guard let r = name.range(of: "/", options: .backwards) else { return "" }
        return String(name[..<r.lowerBound])
    }
    /// "user@host" の形
    var displayAddress: String { user.isEmpty ? host : "\(user)@\(host)" }
    var defaultName: String { displayAddress }
}

/// サイトの保存場所 (UserDefaults) とパスワード (Keychain)
final class SiteStore {
    static let shared = SiteStore()
    static let changed = Notification.Name("SiteStoreChanged")
    private let key = "Sites"
    private(set) var sites: [Site] = []
    /// 空のフォルダ (サイトの無いフォルダも残すため)
    private(set) var folders: [String] = []

    init() { load() }

    func load() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([Site].self, from: d) {
            sites = s
        }
        folders = UserDefaults.standard.stringArray(forKey: "SiteFolders") ?? []
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: key) }
        UserDefaults.standard.set(folders, forKey: "SiteFolders")
        NotificationCenter.default.post(name: SiteStore.changed, object: self)
    }

    func site(_ id: UUID) -> Site? {
        guard var s = sites.first(where: { $0.id == id }) else { return nil }
        if s.savePassword { s.password = Keychain.get(s.id.uuidString) ?? "" }
        return s
    }

    func save(_ s: Site) {
        var s = s
        if s.savePassword && !s.password.isEmpty { Keychain.set(s.id.uuidString, s.password) }
        if !s.savePassword { Keychain.delete(s.id.uuidString) }
        s.password = ""
        if let i = sites.firstIndex(where: { $0.id == s.id }) { sites[i] = s } else { sites.append(s) }
        sites.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(_ id: UUID) {
        Keychain.delete(id.uuidString)
        sites.removeAll { $0.id == id }
        persist()
    }

    func addFolder(_ path: String) {
        if !folders.contains(path) { folders.append(path); folders.sort(); persist() }
    }

    /// フォルダごと消す (中のサイトも)
    func deleteFolder(_ path: String) {
        for s in sites where s.name.hasPrefix(path + "/") { Keychain.delete(s.id.uuidString) }
        sites.removeAll { $0.name.hasPrefix(path + "/") }
        folders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        persist()
    }

    func renameFolder(_ old: String, to new: String) {
        for i in sites.indices where sites[i].name.hasPrefix(old + "/") {
            sites[i].name = new + sites[i].name.dropFirst(old.count)
        }
        folders = folders.map { $0 == old || $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 }
        persist()
    }

    /// 同じ名前があれば "(2)" などを付ける
    func uniqueName(_ base: String, except id: UUID? = nil) -> String {
        var n = base, k = 2
        while sites.contains(where: { $0.name == n && $0.id != id }) { n = "\(base) (\(k))"; k += 1 }
        return n
    }

    /// WinSCP.ini から取り込む。取り込んだ数を返す
    func importWinSCP(_ r: WinSCPIni.Result) -> Int {
        var n = 0
        for w in r.sites {
            var s = Site()
            s.name = uniqueName(w.path)
            s.proto = w.proto
            s.ftpSecurity = w.ftpSecurity
            s.host = w.host
            s.port = w.port
            s.user = w.user
            s.password = w.password
            s.savePassword = !w.password.isEmpty
            // Windows のパス (C:\...) の鍵ファイルはそのままでは使えないので空に
            s.keyFile = w.keyFile.contains("\\") ? "" : w.keyFile
            s.remoteDirectory = w.remoteDirectory
            s.localDirectory = (w.raw["LocalDirectory"] ?? "").contains("\\") ? "" : (w.raw["LocalDirectory"] ?? "")
            s.settings = w.raw.filter { !["HostName", "PortNumber", "UserName", "Password", "FSProtocol", "Ftps", "RemoteDirectory", "LocalDirectory", "PublicKeyFile"].contains($0.key) }
            if let p = w.raw["FtpPasvMode"] { s.passive = p != "0" }
            save(s)
            n += 1
        }
        return n
    }
}

enum Keychain {
    static let service = "net.satoru.winscpmac"

    static func set(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "WinSCP Mac",
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// WinSCP.ini の設定の場所 (WinConfiguration.cpp などの BLOCK(L"Interface", ...) と同じ)
enum WinSCPKey {
    static let root = "Configuration\\"
    static let interface = "Configuration\\Interface\\"
    static let copyParam = "Configuration\\Interface\\CopyParam\\"
    static let editor = "Configuration\\Interface\\Editor\\"
    static let commander = "Configuration\\Interface\\Commander\\"
    static let explorer = "Configuration\\Interface\\Explorer\\"
    static let queueView = "Configuration\\Interface\\QueueView\\"
    static let updates = "Configuration\\Interface\\Updates\\"
    static let logging = "Configuration\\Logging\\"
    static let security = "Configuration\\Security\\"
}

/// WinSCP の「エディタ」の 1 つ (Configuration\Interface\Editor\<番号>\...、TEditorPreferences)
struct EditorEntry: Equatable {
    /// TEditor: edInternal, edExternal, edOpen
    static let internalEditor = 0, externalEditor = 1, openEditor = 2
    var fileMask = "*.*"
    var editor = EditorEntry.internalEditor
    var externalEditorPath = ""
    var externalEditorText = false
    var sdiExternalEditor = false
    var detectMDIExternalEditor = false

    /// Mac で使える外部エディタか (Windows の "notepad.exe" などは使えない)
    var isUsableOnMac: Bool {
        editor != EditorEntry.externalEditor || Prefs.isMacPath(externalEditorPath)
    }

    /// 一覧に出す名前 (TEditorPreferences::GetName と同じ)
    var name: String {
        switch editor {
        case EditorEntry.internalEditor:
            return Translations.clean(Translations.shared.resource("INTERNAL_EDITOR_NAME") ?? "内蔵エディタ")
        case EditorEntry.openEditor:
            return Translations.clean(Translations.shared.resource("OPEN_EDITOR_NAME") ?? "規定のアプリケーション")
        default:
            var p = externalEditorPath.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("\""), let e = p.dropFirst().firstIndex(of: "\"") { p = String(p[p.index(after: p.startIndex)..<e]) }
            var n = (p.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            if let dot = n.range(of: ".", options: .backwards), dot.lowerBound != n.startIndex { n = String(n[..<dot.lowerBound]) }
            if n.uppercased() == n { n = n.lowercased() }
            return n.isEmpty ? p : n
        }
    }

    /// WinSCP のファイル マスク ("*.txt; *.htm|*.bak") に合うか (簡易版)
    func matches(_ fileName: String) -> Bool { EditorEntry.mask(fileMask, matches: fileName) }

    static func mask(_ mask: String, matches fileName: String) -> Bool {
        let parts = mask.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        func list(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func one(_ m: String) -> Bool {
            if m == "*.*" || m == "*" { return true }
            if m.hasSuffix("/") { return false }  // ディレクトリのマスク
            return fnmatch(m, fileName, FNM_CASEFOLD) == 0
        }
        let inc = list(parts.first ?? ""), exc = parts.count > 1 ? list(parts[1]) : []
        return (inc.isEmpty || inc.contains(where: one)) && !exc.contains(where: one)
    }
}

/// アプリの設定。WinSCP と同じキー (WinSCP.ini の Configuration\...) で WinSCPConfig に持つので、
/// Windows 版から取り込んだ設定がそのまま効き、書き出せば Windows 版でも使える
enum Prefs {
    static var c: WinSCPConfig { .shared }
    private static let I = WinSCPKey.interface

    /// パネル: 隠しファイルを表示する (ShowHiddenFiles)
    static var showHidden: Bool { get { c.bool(I + "ShowHiddenFiles", false) } set { c.set(I + "ShowHiddenFiles", newValue) } }
    /// 確認: ファイルの削除時に確認する (ConfirmDeleting)
    static var confirmDelete: Bool { get { c.bool(I + "ConfirmDeleting", true) } set { c.set(I + "ConfirmDeleting", newValue) } }
    /// 確認: ファイルをゴミ箱へ移動時に確認する (ConfirmRecycling)
    static var confirmRecycle: Bool { get { c.bool(I + "ConfirmRecycling", true) } set { c.set(I + "ConfirmRecycling", newValue) } }
    /// 確認: ファイルの上書き時に確認する (ConfirmOverwriting)
    static var confirmOverwrite: Bool { get { c.bool(I + "ConfirmOverwriting", true) } set { c.set(I + "ConfirmOverwriting", newValue) } }
    /// 確認: ファイルの転送時に確認する (ConfirmTransferring)。転送の前にコピーのダイアログを出す
    static var showCopyDialog: Bool { get { c.bool(I + "ConfirmTransferring", true) } set { c.set(I + "ConfirmTransferring", newValue) } }
    /// 既定の転送設定: 更新日時を保持する (CopyParam\PreserveTime)
    static var preserveTime: Bool {
        get { c.bool(WinSCPKey.copyParam + "PreserveTime", true) }
        set { c.set(WinSCPKey.copyParam + "PreserveTime", newValue) }
    }
    /// 確認: アプリケーション終了でセッションを閉じる時に確認する (ConfirmClosingSession)
    static var confirmDisconnect: Bool { get { c.bool(I + "ConfirmClosingSession", true) } set { c.set(I + "ConfirmClosingSession", newValue) } }

    /// エディタの一覧 (環境設定 → エディタ)。上から順に、ファイル マスクに合う最初のものを使う
    static var editors: [EditorEntry] {
        get { c.editorList }
        set { c.editorList = newValue }
    }

    /// そのファイルの編集に使うエディタ (Mac で使えないものはとばす)
    static func editor(forFile name: String) -> EditorEntry {
        editors.first { $0.isUsableOnMac && $0.matches(name) } ?? EditorEntry()
    }

    /// 編集に使うアプリ (空なら、ファイルの種類ごとの既定のアプリ。無ければテキストエディット)
    /// エディタの一覧の最初の項目が Mac の外部エディタならそのパス
    static var editorApp: String {
        get {
            guard let e = editors.first(where: { $0.isUsableOnMac }), e.editor == EditorEntry.externalEditor else { return "" }
            return e.externalEditorPath
        }
        set {
            var list = editors.filter { !($0.editor == EditorEntry.externalEditor && $0.externalEditorPath == newValue) }
            if newValue.isEmpty {
                list.removeAll { $0.editor == EditorEntry.externalEditor && isMacPath($0.externalEditorPath) && $0.fileMask == "*.*" }
                if list.isEmpty { list = [EditorEntry()] }
            } else {
                var e = EditorEntry()
                e.editor = EditorEntry.externalEditor
                e.externalEditorPath = newValue
                list.insert(e, at: 0)
            }
            editors = list
        }
    }

    /// ターミナル (WinSCP の PuttyPath。空か Windows のパスなら Tera Term Mac があればそれ、無ければターミナル.app)
    static var terminalApp: String {
        get {
            let p = c.string(I + "PuttyPath")
            return isMacPath(p) ? p : ""
        }
        set { c.set(I + "PuttyPath", newValue.isEmpty ? nil : newValue) }
    }

    /// Windows のパス (C:\...、%ProgramFiles%\...、notepad.exe) でなく、Mac で使えるパスか
    static func isMacPath(_ p: String) -> Bool {
        let t = p.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.contains("\\") && !t.contains("%") && !t.lowercased().hasSuffix(".exe") && (t.hasPrefix("/") || t.hasPrefix("~"))
    }

    /// インターフェース: テーマ (DarkTheme。TAutoSwitch: 0 = ダーク, 1 = ライト, 2 = 自動)
    static var darkTheme: Int { get { c.int(I + "DarkTheme", 2) } set { c.set(I + "DarkTheme", newValue) } }

    /// テーマをアプリに反映する
    static func applyTheme() {
        switch darkTheme {
        case 0: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case 1: NSApp?.appearance = NSAppearance(named: .aqua)
        default: NSApp?.appearance = nil
        }
    }
}

/// WinSCP の環境設定 (WinSCP.ini の "Configuration\\Interface\\ConfirmDeleting" などのキー名で持つ)
/// Windows 版の WinSCP.ini を読み込めば、そのまま引き継がれる
final class WinSCPConfig {
    static let shared = WinSCPConfig()
    static let changed = Notification.Name("WinSCPConfigChanged")
    private let key = "WinSCPConfig"
    private(set) var values: [String: String]

    init() {
        values = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        migrateLegacy()
    }

    func string(_ k: String, _ def: String = "") -> String { values[k] ?? def }
    func int(_ k: String, _ def: Int) -> Int { values[k].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? def }
    func bool(_ k: String, _ def: Bool) -> Bool {
        guard let v = values[k] else { return def }
        return WinSCPConfig.isTrue(v)
    }
    /// WinSCP の Bool の値 (1 / on / true)
    static func isTrue(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "on" || t == "true" || (Int(t).map { $0 != 0 } ?? false)
    }
    /// WinSCP の DateTime / Float (8 バイトの double を 16 進で。DateTime は日数) を秒で
    func seconds(_ k: String, _ def: Double) -> Double {
        guard let v = values[k] else { return def }
        if let d = WinSCPConfig.decodeDouble(v) { return d * 86400 }
        return def
    }
    func set(_ k: String, _ v: String?) { update([k: v]) }
    func set(_ k: String, _ v: Bool) { set(k, v ? "1" : "0") }
    func set(_ k: String, _ v: Int) { set(k, String(v)) }

    /// まとめて変える (nil は消す)。通知は 1 回
    func update(_ changes: [String: String?]) {
        guard !changes.isEmpty else { return }
        for (k, v) in changes { values[k] = v }
        UserDefaults.standard.set(values, forKey: key)
        NotificationCenter.default.post(name: WinSCPConfig.changed, object: self)
    }

    /// WinSCP.ini から読んだ設定を取り込む
    func merge(_ c: [String: String]) {
        // エディタの一覧は WinSCP と同じく丸ごと置き換える (番号がずれて混ざらないように)
        if c.keys.contains(where: { WinSCPConfig.isEditorListKey($0) }) {
            for k in values.keys where WinSCPConfig.isEditorListKey(k) { values[k] = nil }
        }
        for (k, v) in c where k.hasPrefix("Configuration\\") { values[k] = v }
        UserDefaults.standard.set(values, forKey: key)
        NotificationCenter.default.post(name: WinSCPConfig.changed, object: self)
    }

    // MARK: 値の形式 (WinSCP の THierarchicalStorage と同じ)

    /// 8 バイトの double (リトルエンディアン) の 16 進 → 値
    static func decodeDouble(_ hex: String) -> Double? {
        let h = Array(hex.utf8)
        guard h.count == 16 else { return Double(hex) }
        var bits: UInt64 = 0
        for k in 0..<8 {
            guard let b = UInt8(String(decoding: h[(k * 2)..<(k * 2 + 2)], as: UTF8.self), radix: 16) else { return nil }
            bits |= UInt64(b) << (8 * UInt64(k))
        }
        return Double(bitPattern: bits)
    }
    static func encodeDouble(_ d: Double) -> String {
        let bits = d.bitPattern
        return (0..<8).map { String(format: "%02X", (bits >> (8 * UInt64($0))) & 0xFF) }.joined()
    }
    /// 秒 → WinSCP の DateTime (日数) の 16 進
    static func dateTime(seconds: Double) -> String { encodeDouble(seconds / 86400) }

    // MARK: エディタの一覧 (Configuration\Interface\Editor\0\Editor など)

    static func isEditorListKey(_ k: String) -> Bool {
        guard k.hasPrefix(WinSCPKey.editor) else { return false }
        let rest = k.dropFirst(WinSCPKey.editor.count)
        guard let sep = rest.firstIndex(of: "\\") else { return false }
        return !rest[..<sep].isEmpty && rest[..<sep].allSatisfy(\.isNumber)
    }

    var editorList: [EditorEntry] {
        get {
            var out: [EditorEntry] = []
            var i = 0
            while true {
                let p = WinSCPKey.editor + "\(i)\\"
                guard values.keys.contains(where: { $0.hasPrefix(p) }) else { break }
                var e = EditorEntry()
                e.fileMask = string(p + "FileMask", "*.*")
                e.editor = int(p + "Editor", EditorEntry.internalEditor)
                e.externalEditorPath = string(p + "ExternalEditor")
                e.externalEditorText = bool(p + "ExternalEditorText", false)
                e.sdiExternalEditor = bool(p + "SDIExternalEditor", false)
                e.detectMDIExternalEditor = bool(p + "DetectMDIExternalEditor", false)
                out.append(e)
                i += 1
            }
            // 無ければ WinSCP と同じく内蔵エディタだけ
            return out.isEmpty ? [EditorEntry()] : out
        }
        set {
            var ch: [String: String?] = [:]
            for k in values.keys where WinSCPConfig.isEditorListKey(k) { ch[k] = .some(nil) }
            for (i, e) in newValue.enumerated() {
                let p = WinSCPKey.editor + "\(i)\\"
                ch[p + "FileMask"] = e.fileMask
                ch[p + "Editor"] = String(e.editor)
                ch[p + "ExternalEditor"] = e.externalEditorPath
                ch[p + "ExternalEditorText"] = e.externalEditorText ? "1" : "0"
                ch[p + "SDIExternalEditor"] = e.sdiExternalEditor ? "1" : "0"
                ch[p + "DetectMDIExternalEditor"] = e.detectMDIExternalEditor ? "1" : "0"
            }
            update(ch)
        }
    }

    /// 以前の版の設定 (UserDefaults の "ShowHidden" など) を WinSCP のキーへ移す
    private func migrateLegacy() {
        let d = UserDefaults.standard
        let I = WinSCPKey.interface
        let map = ["ShowHidden": I + "ShowHiddenFiles", "ConfirmDelete": I + "ConfirmDeleting",
                   "ConfirmOverwrite": I + "ConfirmOverwriting", "ShowCopyDialog": I + "ConfirmTransferring",
                   "PreserveTime": WinSCPKey.copyParam + "PreserveTime", "ConfirmDisconnect": I + "ConfirmClosingSession"]
        var moved = false
        for (old, new) in map where d.object(forKey: old) != nil {
            if values[new] == nil { values[new] = d.bool(forKey: old) ? "1" : "0" }
            d.removeObject(forKey: old)
            moved = true
        }
        if let t = d.string(forKey: "TerminalApp") {
            if !t.isEmpty && values[I + "PuttyPath"] == nil { values[I + "PuttyPath"] = t }
            d.removeObject(forKey: "TerminalApp")
            moved = true
        }
        if let e = d.string(forKey: "EditorApp") {
            if !e.isEmpty && !values.keys.contains(where: WinSCPConfig.isEditorListKey) {
                let p = WinSCPKey.editor + "0\\"
                values[p + "FileMask"] = "*.*"
                values[p + "Editor"] = String(EditorEntry.externalEditor)
                values[p + "ExternalEditor"] = e
            }
            d.removeObject(forKey: "EditorApp")
            moved = true
        }
        if moved { d.set(values, forKey: key) }
    }
}

