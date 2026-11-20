import Foundation
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

/// アプリの設定
enum Prefs {
    static var d: UserDefaults { .standard }
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    static var showHidden: Bool { get { bool("ShowHidden", false) } set { d.set(newValue, forKey: "ShowHidden") } }
    static var confirmDelete: Bool { get { bool("ConfirmDelete", true) } set { d.set(newValue, forKey: "ConfirmDelete") } }
    static var confirmOverwrite: Bool { get { bool("ConfirmOverwrite", true) } set { d.set(newValue, forKey: "ConfirmOverwrite") } }
    static var showCopyDialog: Bool { get { bool("ShowCopyDialog", true) } set { d.set(newValue, forKey: "ShowCopyDialog") } }
    static var preserveTime: Bool { get { bool("PreserveTime", true) } set { d.set(newValue, forKey: "PreserveTime") } }
    static var confirmDisconnect: Bool { get { bool("ConfirmDisconnect", true) } set { d.set(newValue, forKey: "ConfirmDisconnect") } }
    /// 編集に使うアプリ (空なら、ファイルの種類ごとの既定のアプリ。無ければテキストエディット)
    static var editorApp: String { get { d.string(forKey: "EditorApp") ?? "" } set { d.set(newValue, forKey: "EditorApp") } }
    /// ターミナル (空なら Tera Term Mac があればそれ、無ければターミナル.app)
    static var terminalApp: String { get { d.string(forKey: "TerminalApp") ?? "" } set { d.set(newValue, forKey: "TerminalApp") } }
}

/// WinSCP の環境設定 (WinSCP.ini の "Configuration\\Interface\\ConfirmDeleting" などのキー名で持つ)
/// Windows 版の WinSCP.ini を読み込めば、そのまま引き継がれる
final class WinSCPConfig {
    static let shared = WinSCPConfig()
    static let changed = Notification.Name("WinSCPConfigChanged")
    private let key = "WinSCPConfig"
    private(set) var values: [String: String]

    init() { values = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    func string(_ k: String, _ def: String = "") -> String { values[k] ?? def }
    func int(_ k: String, _ def: Int) -> Int { values[k].flatMap { Int($0) } ?? def }
    func bool(_ k: String, _ def: Bool) -> Bool {
        guard let v = values[k] else { return def }
        return v == "1" || v.lowercased() == "on" || v.lowercased() == "true"
    }
    func set(_ k: String, _ v: String?) {
        values[k] = v
        UserDefaults.standard.set(values, forKey: key)
        NotificationCenter.default.post(name: WinSCPConfig.changed, object: self)
    }
    func set(_ k: String, _ v: Bool) { set(k, v ? "1" : "0") }
    func set(_ k: String, _ v: Int) { set(k, String(v)) }

    /// WinSCP.ini から読んだ設定を取り込む
    func merge(_ c: [String: String]) {
        for (k, v) in c where k.hasPrefix("Configuration\\") { values[k] = v }
        UserDefaults.standard.set(values, forKey: key)
        NotificationCenter.default.post(name: WinSCPConfig.changed, object: self)
    }
}
