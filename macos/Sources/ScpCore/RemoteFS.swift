import Foundation

/// 一覧に出す 1 つのファイル (ローカルもリモートも同じ形で扱う)
public struct FileEntry: Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: UInt64
    public var mtime: Date?
    /// UNIX のパーミッション (下位 12 ビット)。不明なら nil
    public var permissions: UInt32?
    public var owner: String
    public var group: String
    /// シンボリックリンクの行き先 (分かれば)
    public var linkTarget: String?

    public init(name: String, isDirectory: Bool, isSymlink: Bool = false, size: UInt64 = 0, mtime: Date? = nil,
                permissions: UInt32? = nil, owner: String = "", group: String = "", linkTarget: String? = nil) {
        self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.size = size
        self.mtime = mtime; self.permissions = permissions; self.owner = owner; self.group = group; self.linkTarget = linkTarget
    }

    /// "rwxr-xr-x" の形
    public var rightsString: String {
        guard let p = permissions else { return "" }
        return FileEntry.rights(p)
    }

    public static func rights(_ p: UInt32) -> String {
        let chars: [Character] = ["r", "w", "x"]
        var s = ""
        for i in 0..<9 {
            let bit = UInt32(1) << UInt32(8 - i)
            s.append(p & bit != 0 ? chars[i % 3] : "-")
        }
        var a = Array(s)
        if p & 0o4000 != 0 { a[2] = a[2] == "x" ? "s" : "S" }
        if p & 0o2000 != 0 { a[5] = a[5] == "x" ? "s" : "S" }
        if p & 0o1000 != 0 { a[8] = a[8] == "x" ? "t" : "T" }
        return String(a)
    }
}

public enum FileProtocol: Int, Codable, CaseIterable {
    case sftp = 0, scp = 1, ftp = 2

    public var title: String {
        switch self {
        case .sftp: return "SFTP"
        case .scp: return "SCP"
        case .ftp: return "FTP"
        }
    }
    public var defaultPort: Int { self == .ftp ? 21 : 22 }
}

public enum FTPSecurity: Int, Codable, CaseIterable {
    case none = 0, explicitTLS = 1, implicitTLS = 2
    public var title: String {
        switch self {
        case .none: return "暗号化なし"
        case .explicitTLS: return "TLS/SSL 明示的な暗号化"
        case .implicitTLS: return "TLS/SSL 暗黙的な暗号化"
        }
    }
}

public struct RemoteError: LocalizedError {
    public let message: String
    public let code: Int
    public init(_ message: String, code: Int = 0) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
    public static let cancelled = RemoteError("中止しました", code: -999)
    public var isCancelled: Bool { code == -999 }
}

/// 転送の進み具合を知らせる。false を返すと中止
public typealias ProgressHandler = (_ bytesDone: UInt64) -> Bool

/// リモートのファイルシステム (SFTP / SCP / FTP)。呼び出しはすべて同期 (バックグラウンドのキューから呼ぶ)
public protocol RemoteFileSystem: AnyObject {
    var protocolName: String { get }
    /// ログイン直後のディレクトリ
    func homeDirectory() throws -> String
    func list(_ path: String) throws -> [FileEntry]
    func stat(_ path: String) throws -> FileEntry
    func download(_ remote: String, to local: URL, offset: UInt64, progress: ProgressHandler) throws
    func upload(_ local: URL, to remote: String, progress: ProgressHandler) throws
    func makeDirectory(_ path: String) throws
    func removeFile(_ path: String) throws
    func removeDirectory(_ path: String) throws
    func rename(_ from: String, to: String) throws
    func setPermissions(_ path: String, _ mode: UInt32) throws
    func setModificationTime(_ path: String, _ date: Date) throws
    /// 任意のコマンドを実行できるなら出力を返す (SCP/SFTP は ssh で、FTP は SITE/生コマンド)
    func runCommand(_ command: String, in directory: String) throws -> String
    func close()
}

public extension RemoteFileSystem {
    func runCommand(_ command: String, in directory: String) throws -> String {
        throw RemoteError("このプロトコルではコマンドを実行できません")
    }
}

/// リモートのパス操作 (常に "/" 区切り)
public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    public static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let r = p.range(of: "/", options: .backwards) else { return "/" }
        let s = String(p[p.startIndex..<r.lowerBound])
        return s.isEmpty ? "/" : s
    }
    public static func name(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if let r = p.range(of: "/", options: .backwards) { return String(p[r.upperBound...]) }
        return p
    }
    /// "a/../b" や "./" を整理する
    public static func normalize(_ path: String) -> String {
        var out: [String] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(String(c))
        }
        return "/" + out.joined(separator: "/")
    }
}
