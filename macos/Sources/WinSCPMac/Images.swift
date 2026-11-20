import AppKit

/// WinSCP 自身の絵 (.dfm の TPngImageList に PNG で入っている) を取り出す。
///   Glyphs.dfm / Glyphs192.dfm の ExplorerImages … メニュー・ツールバーの 16px の絵 (アクションの ImageIndex)
///   Animations96.dfm / Animations192.dfm の DialogImages … ダイアログの 32px の絵 (名前で引く)
///   同 AnimationImages … 進行状況のアニメーション (CopyRemote_1_10 など)
enum WinSCPImages {
    /// .dfm の中の 1 つの画像リストを (名前, PNG) の並びで読む。
    /// 大きなファイルなので、汎用の .dfm 読み込みを使わずバイト列を直接見る
    static func pngList(file: String, list: String) -> [(name: String, data: Data)] {
        guard let u = Resources.url(file), let d = try? Data(contentsOf: u) else { return [] }
        let bytes = [UInt8](d)
        func find(_ s: String, from: Int, to: Int? = nil) -> Int? {
            let pat = [UInt8](s.utf8)
            let end = (to ?? bytes.count) - pat.count
            guard from <= end, let first = pat.first else { return nil }
            var i = from
            while i <= end {
                if bytes[i] == first {
                    var ok = true
                    for k in 1..<pat.count where bytes[i + k] != pat[k] { ok = false; break }
                    if ok { return i }
                }
                i += 1
            }
            return nil
        }
        guard let start = find("object \(list):", from: 0) else { return [] }
        // 次の同じ深さの object まで
        let stop = find("\n  object ", from: start + 1) ?? bytes.count
        var out: [(String, Data)] = []
        var p = start
        while let n = find("Name = '", from: p, to: stop) {
            let ns = n + 8
            var ne = ns
            while ne < stop && bytes[ne] != 0x27 { ne += 1 }
            let name = String(decoding: bytes[ns..<ne], as: UTF8.self)
            guard let ds = find("PngImage.Data = {", from: ne, to: stop) else { break }
            var de = ds + 17
            while de < stop && bytes[de] != 0x7D { de += 1 }
            out.append((name, DFMValue.decodeHex(bytes[(ds + 17)..<de])))
            p = de
        }
        return out
    }

    /// 等倍と 2 倍の PNG から 1 つの NSImage を作る (Retina では 2 倍のほう)
    static func make(_ lo: [(name: String, data: Data)], _ hi: [(name: String, data: Data)], index: Int, size: CGFloat) -> NSImage? {
        guard index >= 0, index < lo.count else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size))
        for d in [lo[index].data] + (index < hi.count ? [hi[index].data] : []) {
            if let r = NSBitmapImageRep(data: d) {
                r.size = NSSize(width: size, height: size)
                img.addRepresentation(r)
            }
        }
        return img.representations.isEmpty ? nil : img
    }

    private static var explorerLo: [(name: String, data: Data)]?
    private static var explorerHi: [(name: String, data: Data)] = []
    private static var explorerCache: [Int: NSImage] = [:]

    /// GlyphsModule.ExplorerImages の index 番目 (アクションの ImageIndex)
    static func explorer(_ index: Int) -> NSImage? {
        if let i = explorerCache[index] { return i }
        if explorerLo == nil {
            explorerLo = pngList(file: "Glyphs.dfm", list: "ExplorerImages")
            explorerHi = pngList(file: "Glyphs192.dfm", list: "ExplorerImages")
        }
        let i = make(explorerLo ?? [], explorerHi, index: index, size: 16)
        explorerCache[index] = i
        return i
    }

    private static var dialogLo: [(name: String, data: Data)]?
    private static var dialogHi: [(name: String, data: Data)] = []

    /// ダイアログの絵 (WinSCP の LoadDialogImage と同じ名前: "Upload File", "Download File" など)
    static func dialog(_ name: String) -> NSImage? {
        if dialogLo == nil {
            dialogLo = pngList(file: "Animations96.dfm", list: "DialogImages")
            dialogHi = pngList(file: "Animations192.dfm", list: "DialogImages")
        }
        guard let lo = dialogLo, let i = lo.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let hi = dialogHi.count == lo.count ? dialogHi : []
        return make(lo, hi, index: i, size: 32)
    }

    private static var animLo: [(name: String, data: Data)]?
    private static var animHi: [(name: String, data: Data)] = []

    /// アニメーションのこま (WinSCP の TFrameAnimation: "CopyRemote" → CopyRemote_1_10, CopyRemote_2_10, ...)
    static func animation(_ name: String) -> [NSImage] {
        if animLo == nil {
            animLo = pngList(file: "Animations96.dfm", list: "AnimationImages")
            animHi = pngList(file: "Animations192.dfm", list: "AnimationImages")
        }
        guard let lo = animLo else { return [] }
        let hi = animHi.count == lo.count ? animHi : []
        return lo.indices.filter { lo[$0].name.hasPrefix(name + "_") }.compactMap { make(lo, hi, index: $0, size: 32) }
    }
}
