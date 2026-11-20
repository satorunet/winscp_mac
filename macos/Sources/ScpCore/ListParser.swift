import Foundation

/// "ls -la" 形式 (FTP の LIST や SCP で使う) と MLSD を読む
public enum ListParser {
    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                         "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    public static func parseUnixList(_ text: String, now: Date = Date(), utc: Bool = false) -> [FileEntry] {
        var out: [FileEntry] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            if let e = parseUnixLine(String(raw), now: now, utc: utc), e.name != ".", e.name != ".." { out.append(e) }
        }
        return out
    }

    static func parseMode(_ s: Substring) -> UInt32? {
        let a = Array(s)
        guard a.count >= 10 else { return nil }
        var m: UInt32 = 0
        let bits: [UInt32] = [0o400, 0o200, 0o100, 0o40, 0o20, 0o10, 0o4, 0o2, 0o1]
        for i in 0..<9 {
            let c = a[i + 1]
            if c != "-" && c != "S" && c != "T" { m |= bits[i] }
        }
        if a[3] == "s" || a[3] == "S" { m |= 0o4000 }
        if a[6] == "s" || a[6] == "S" { m |= 0o2000 }
        if a[9] == "t" || a[9] == "T" { m |= 0o1000 }
        return m
    }

    /// 1 行を読む。読めなければ nil
    public static func parseUnixLine(_ line: String, now: Date = Date(), utc: Bool = false) -> FileEntry? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }
        // 列を区切るが、名前の部分は空白を含みうるので位置を覚えておく
        var cols: [(Substring, String.Index)] = []
        var i = line.startIndex
        while i < line.endIndex && cols.count < 9 {
            while i < line.endIndex && line[i] == " " { i = line.index(after: i) }
            guard i < line.endIndex else { break }
            let s = i
            while i < line.endIndex && line[i] != " " { i = line.index(after: i) }
            cols.append((line[s..<i], s))
        }
        guard cols.count >= 8 else { return nil }
        let mode = parseMode(cols[0].0)
        // 月の位置を探す (グループ列が無い形式にも対応)
        var mi = -1
        for k in 3..<min(cols.count, 7) where months[cols[k].0.lowercased()] != nil {
            if k + 2 < cols.count, UInt64(cols[k - 1].0) != nil { mi = k; break }
        }
        // ISO 形式 (ls --full-time や --time-style=long-iso): "2025-11-20 13:45:00.000 +0900"
        var date: Date?
        var nameStart: String.Index
        var size: UInt64 = 0
        var owner = "", group = ""
        var cal = Calendar(identifier: .gregorian)
        if utc { cal.timeZone = TimeZone(identifier: "UTC")! }
        if mi >= 0 {
            size = UInt64(cols[mi - 1].0) ?? 0
            owner = mi >= 3 ? String(cols[2].0) : ""
            group = mi >= 4 ? String(cols[3].0) : ""
            let mon = months[cols[mi].0.lowercased()]!
            let day = Int(cols[mi + 1].0) ?? 1
            let ty = cols[mi + 2].0
            var dc = DateComponents()
            dc.month = mon; dc.day = day
            if ty.contains(":") {
                let hm = ty.split(separator: ":")
                dc.hour = Int(hm[0]); dc.minute = hm.count > 1 ? Int(hm[1]) : 0
                let y = cal.component(.year, from: now)
                dc.year = y
                // 半年以上先になるなら去年のこと
                if let d = cal.date(from: dc), d.timeIntervalSince(now) > 86400 * 2 { dc.year = y - 1 }
            } else {
                dc.year = Int(ty)
            }
            date = cal.date(from: dc)
            guard mi + 3 < cols.count else {
                // 名前の列が 9 列目以降にかかって切られている
                return nil
            }
            nameStart = cols[mi + 3].1
        } else if cols.count >= 8, cols[5].0.count == 10, cols[5].0.contains("-") {
            // perm links owner group size YYYY-MM-DD HH:MM[:SS] [tz] name
            size = UInt64(cols[4].0) ?? 0
            owner = String(cols[2].0); group = String(cols[3].0)
            let ds = cols[5].0.split(separator: "-").compactMap { Int($0) }
            let ts = cols[6].0.split(separator: ":").map { Double($0) ?? 0 }
            var dc = DateComponents()
            if ds.count == 3 { dc.year = ds[0]; dc.month = ds[1]; dc.day = ds[2] }
            if ts.count >= 2 { dc.hour = Int(ts[0]); dc.minute = Int(ts[1]); dc.second = ts.count > 2 ? Int(ts[2]) : 0 }
            var k = 7
            if cols.count > 8, let tz = cols[7].0.first, tz == "+" || tz == "-", cols[7].0.count == 5 {
                let v = Int(cols[7].0.dropFirst()) ?? 0
                let sec = (v / 100 * 3600 + v % 100 * 60) * (tz == "-" ? -1 : 1)
                cal.timeZone = TimeZone(secondsFromGMT: sec) ?? cal.timeZone
                k = 8
            }
            date = cal.date(from: dc)
            guard k < cols.count else { return nil }
            nameStart = cols[k].1
        } else {
            return nil
        }
        var name = String(line[nameStart...])
        var target: String?
        if first == "l", let r = name.range(of: " -> ") {
            target = String(name[r.upperBound...])
            name = String(name[..<r.lowerBound])
        }
        return FileEntry(name: name, isDirectory: first == "d", isSymlink: first == "l", size: size, mtime: date,
                         permissions: mode, owner: owner, group: group, linkTarget: target)
    }

    /// MLSD / MLST の 1 行: "type=file;size=123;modify=20251120134500; name"
    public static func parseMLSDLine(_ line: String) -> FileEntry? {
        guard let sp = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<sp]
        let name = String(line[line.index(after: sp)...])
        var e = FileEntry(name: name, isDirectory: false)
        var type = ""
        for f in facts.split(separator: ";") {
            let kv = f.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].lowercased(), v = String(kv[1])
            switch k {
            case "type": type = v.lowercased()
            case "size", "sizd": e.size = UInt64(v) ?? 0
            case "modify": e.mtime = parseMDTM(v)
            case "unix.mode": e.permissions = UInt32(v, radix: 8)
            case "unix.owner", "unix.ownername": if e.owner.isEmpty || k == "unix.ownername" { e.owner = v }
            case "unix.group", "unix.groupname": if e.group.isEmpty || k == "unix.groupname" { e.group = v }
            case "perm": break
            default: break
            }
        }
        if type == "cdir" || type == "pdir" || name == "." || name == ".." { return nil }
        e.isDirectory = type == "dir"
        if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") { e.isSymlink = true }
        return e
    }

    /// "20251120134500" や "20251120134500.123" (UTC)
    public static func parseMDTM(_ s: String) -> Date? {
        let digits = s.split(separator: ".")[0]
        guard digits.count >= 14 else { return nil }
        let a = Array(digits)
        func n(_ r: Range<Int>) -> Int { Int(String(a[r])) ?? 0 }
        var dc = DateComponents()
        dc.year = n(0..<4); dc.month = n(4..<6); dc.day = n(6..<8)
        dc.hour = n(8..<10); dc.minute = n(10..<12); dc.second = n(12..<14)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: dc)
    }

    public static func formatMDTM(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: d)
    }
}
