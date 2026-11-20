import AppKit

// WinSCP (Delphi/C++Builder) のフォーム定義 (.dfm) と日本語訳 (JP.ini) から、
// 同じ配置・同じ文言の AppKit の画面を組み立てる。
// 配置は .dfm の座標 (96 dpi のピクセル) をそのままポイントとして使う。

// MARK: - .dfm の読み込み

indirect enum DFMValue {
    case string(String)
    case number(Double)
    case ident(String)
    case set([String])
    case list([DFMValue])
    case collection([[String: DFMValue]])
    /// {...} の 16 進のデータ (TTreeView の Items.NodeData など)
    case binary(Data)

    var string: String? {
        switch self {
        case .string(let s): return s
        case .ident(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var data: Data? { if case .binary(let d) = self { return d }; return nil }
    var bool: Bool? { if case .ident(let s) = self { return s == "True" }; return nil }
    var strings: [String] {
        switch self {
        case .list(let l): return l.compactMap { $0.string }
        case .set(let s): return s
        default: return []
        }
    }
}

final class DFMObject {
    let name: String
    let className: String
    var props: [String: DFMValue] = [:]
    var children: [DFMObject] = []
    weak var parent: DFMObject?
    init(name: String, className: String) { self.name = name; self.className = className }

    func int(_ k: String) -> Int? { props[k]?.int }
    func str(_ k: String) -> String? { props[k]?.string }
    func bool(_ k: String) -> Bool? { props[k]?.bool }

    /// 名前で子孫を探す
    func find(_ n: String) -> DFMObject? {
        if name == n { return self }
        for c in children { if let f = c.find(n) { return f } }
        return nil
    }

    /// 訳のキーに使うパス (フォームの直下から . でつなぐ)
    var path: String {
        var parts: [String] = []
        var o: DFMObject? = self
        while let x = o, x.parent != nil { parts.append(x.name); o = x.parent }
        return parts.reversed().joined(separator: ".")
    }
}

struct DFMParser {
    private var tokens: [String] = []
    private var i = 0

    static func parse(_ text: String) -> DFMObject? {
        var p = DFMParser()
        p.tokens = DFMParser.tokenize(text)
        return p.parseObject()
    }

    /// 文字列 ('..'#13'..') はまとめて 1 つのトークンにする (先頭に \u{1} を付けて区別)
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." || c == "-" || c == "+" && false }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "'" || c == "#" {
                // 文字列の連結: 'abc'#13#10'def' と、行をまたぐ + 'xyz'
                var s = ""
                while i < chars.count {
                    if chars[i] == "'" {
                        i += 1
                        while i < chars.count {
                            if chars[i] == "'" {
                                if i + 1 < chars.count && chars[i + 1] == "'" { s.append("'"); i += 2; continue }
                                i += 1; break
                            }
                            s.append(chars[i]); i += 1
                        }
                    } else if chars[i] == "#" {
                        i += 1
                        var num = ""
                        while i < chars.count, chars[i].isNumber || chars[i] == "$" || chars[i].isHexDigit { num.append(chars[i]); i += 1 }
                        let v = num.hasPrefix("$") ? Int(num.dropFirst(), radix: 16) : Int(num)
                        if let v = v, let u = UnicodeScalar(v) { s.append(Character(u)) }
                    } else {
                        // 空白をとばして + があれば続ける
                        var j = i
                        while j < chars.count && chars[j].isWhitespace { j += 1 }
                        if j < chars.count && chars[j] == "+" {
                            j += 1
                            while j < chars.count && chars[j].isWhitespace { j += 1 }
                            if j < chars.count && (chars[j] == "'" || chars[j] == "#") { i = j; continue }
                        }
                        break
                    }
                }
                out.append("\u{1}" + s)
                continue
            }
            if "=()[]<>{},:".contains(c) {
                if c == "{" {
                    // バイナリ: 16 進の部分だけ取っておく ("{" + 16 進)
                    var hex = "{"
                    i += 1
                    while i < chars.count && chars[i] != "}" { if chars[i].isHexDigit { hex.append(chars[i]) }; i += 1 }
                    i += 1
                    out.append(hex)
                    continue
                }
                out.append(String(c)); i += 1; continue
            }
            var s = ""
            while i < chars.count, !chars[i].isWhitespace, !"=()[]<>{},:'#".contains(chars[i]) { s.append(chars[i]); i += 1 }
            if s.isEmpty { i += 1 } else { out.append(s) }
        }
        return out
    }

    private var peek: String? { i < tokens.count ? tokens[i] : nil }
    private mutating func next() -> String? { defer { i += 1 }; return peek }

    private mutating func parseObject() -> DFMObject? {
        guard let kw = next(), ["object", "inherited", "inline"].contains(kw), let name = next() else { return nil }
        var cls = ""
        if peek == ":" { _ = next(); cls = next() ?? "" } else { cls = name }
        if peek == "[" { while let t = next(), t != "]" {} }
        let o = DFMObject(name: cls.isEmpty ? "" : name, className: cls)
        while let t = peek {
            if t == "end" { _ = next(); break }
            if ["object", "inherited", "inline"].contains(t) {
                if let c = parseObject() { c.parent = o; o.children.append(c) }
                continue
            }
            // プロパティ
            let key = next()!
            guard peek == "=" else { continue }
            _ = next()
            o.props[key] = parseValue()
        }
        return o
    }

    private mutating func parseValue() -> DFMValue {
        guard let t = next() else { return .ident("") }
        if t.hasPrefix("\u{1}") { return .string(String(t.dropFirst())) }
        if t == "[" {
            var items: [String] = []
            while let x = next(), x != "]" { if x != "," { items.append(x) } }
            return .set(items)
        }
        if t == "(" {
            var items: [DFMValue] = []
            while let x = peek, x != ")" { items.append(parseValue()) }
            _ = next()
            return .list(items)
        }
        if t == "<" {
            var items: [[String: DFMValue]] = []
            while let x = peek, x != ">" {
                if x == "item" {
                    _ = next()
                    var d: [String: DFMValue] = [:]
                    while let y = peek, y != "end" {
                        let k = next()!
                        if peek == "=" { _ = next(); d[k] = parseValue() }
                    }
                    _ = next()
                    items.append(d)
                } else { _ = next() }
            }
            _ = next()
            return .collection(items)
        }
        if t.hasPrefix("{") {
            var d = Data()
            let h = Array(t.utf8.dropFirst())
            var k = 0
            while k + 1 < h.count {
                if let b = UInt8(String(decoding: h[k...k + 1], as: UTF8.self), radix: 16) { d.append(b) }
                k += 2
            }
            return .binary(d)
        }
        if let n = Double(t) { return .number(n) }
        return .ident(t)
    }
}

// MARK: - 日本語訳

final class Translations {
    static let shared = Translations()
    /// [セクション][キー] = 訳
    private var sections: [String: [String: String]] = [:]

    init() {
        guard let url = Resources.url("JP.ini"), let text = try? String(contentsOf: url) else { return }
        var cur = ""
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { cur = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq])
            var v = String(line[line.index(after: eq)...])
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            // 訳の中の改行は \r\n / \n と書かれている
            if v.contains("\\") { v = v.replacingOccurrences(of: "\\r\\n", with: "\n").replacingOccurrences(of: "\\n", with: "\n") }
            sections[cur, default: [:]][k] = v
        }
    }

    func get(_ section: String, _ key: String) -> String? { sections[section]?[key] }

    /// リソースの文字列 (TextsWin1.rc などの LoadStr(ID) の訳。\n は改行に)
    func resource(_ id: String) -> String? {
        for (name, s) in sections where name.hasSuffix(".rc") {
            if let v = s[id] { return v.replacingOccurrences(of: "\\n", with: "\n") }
        }
        return nil
    }

    /// アクセラレータ (&X)、& を取り除く (Mac では使わない)
    static func clean(_ s: String) -> String {
        var r = s
        if let rg = r.range(of: "\\(&.\\)", options: .regularExpression) { r.removeSubrange(rg) }
        r = r.replacingOccurrences(of: "&&", with: "\u{2}").replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "\u{2}", with: "&")
        return r
    }
}

/// 同梱の WinSCP のファイル (forms/*.dfm, JP.ini) を探す
enum Resources {
    static func url(_ name: String) -> URL? {
        if let r = Bundle.main.resourceURL {
            let u = r.appendingPathComponent("winscp").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // 開発中 (swift run): リポジトリの中を見る
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            for sub in ["source/forms", "translations"] {
                let u = dir.appendingPathComponent(sub).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

// MARK: - 画面の組み立て

/// 上から下へ座標をとる入れ物 (VCL と同じ向き)
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// グループボックス (VCL の TGroupBox と同じく、子の座標は枠の左上から)
final class GroupBoxView: FlippedView {
    var title = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let ts = (title as NSString).size(withAttributes: attrs)
        let r = NSRect(x: 0.5, y: 7.5, width: bounds.width - 1, height: bounds.height - 8)
        NSGraphicsContext.saveGraphicsState()
        if !title.isEmpty {
            // 題名の部分だけ枠線を描かない
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(rect: NSRect(x: 6, y: 0, width: ts.width + 6, height: 14)).reversed)
            clip.addClip()
        }
        let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor.separatorColor.setStroke()
        p.lineWidth = 1
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if !title.isEmpty { (title as NSString).draw(at: NSPoint(x: 9, y: 0), withAttributes: attrs) }
    }
}

/// .dfm 1 枚ぶんの画面
final class DFMForm {
    let root: DFMObject
    let section: String
    let view: FlippedView
    private(set) var views: [String: NSView] = [:]
    private(set) var objects: [String: DFMObject] = [:]
    /// TPageControl の中の TTabSheet → タブの項目
    private(set) var tabItems: [String: NSTabViewItem] = [:]
    var translations = Translations.shared
    static let font = NSFont.systemFont(ofSize: 12)

    /// forms/<file> を読む (例 "Login.dfm")
    init?(_ file: String) {
        guard let u = Resources.url(file), let d = try? Data(contentsOf: u) else { return nil }
        // .dfm は ANSI (cp1252) か UTF-8
        let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? ""
        guard let r = DFMParser.parse(text) else { return nil }
        root = r
        section = file
        let w = CGFloat(r.int("ClientWidth") ?? r.int("Width") ?? 400)
        let h = CGFloat(r.int("ClientHeight") ?? r.int("Height") ?? 300)
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        func register(_ o: DFMObject) { objects[o.name] = o; o.children.forEach(register) }
        register(r)
        for c in r.children { build(c, into: view) }
    }

    /// フォームの題名 (訳があれば訳)
    var caption: String { text(root, "Caption") ?? "" }

    func text(_ o: DFMObject, _ prop: String) -> String? {
        // ボタンなどの文言はアクションから来ることがある (Action = LoginAction)
        if prop == "Caption" || prop == "Hint", o.props[prop] == nil, let an = o.str("Action"), let a = objects[an], a !== o {
            return text(a, prop)
        }
        let key = o.parent == nil ? prop : o.path + "." + prop
        if let t = translations.get(section, key) { return Translations.clean(t) }
        return o.str(prop).map(Translations.clean)
    }

    func items(_ o: DFMObject) -> [String] {
        let base = o.props["Items.Strings"]?.strings ?? []
        return base.enumerated().map { i, s in
            translations.get(section, o.path + ".Items.Strings.\(i)").map(Translations.clean) ?? s
        }
    }

    subscript(_ name: String) -> NSView? { views[name] }
    func button(_ n: String) -> NSButton? { views[n] as? NSButton }
    func field(_ n: String) -> NSTextField? { views[n] as? NSTextField }
    func popup(_ n: String) -> NSPopUpButton? { views[n] as? NSPopUpButton }
    func combo(_ n: String) -> NSComboBox? { views[n] as? NSComboBox }
    func stepper(_ n: String) -> NumberField? { views[n] as? NumberField }
    func textView(_ n: String) -> NSTextView? { (views[n] as? NSScrollView)?.documentView as? NSTextView }
    func tabView(_ n: String) -> NSTabView? { views[n] as? NSTabView }
    func label(_ n: String) -> NSTextField? { views[n] as? NSTextField }
    func object(_ n: String) -> DFMObject? { objects[n] }

    /// 下の帯 (ComponentsPanel) を隠して、その分フォームを縮める (WinSCP の HideComponentsPanel)
    /// 下に付いたボタンなどは動かさず、そのままの位置に残る
    func hideComponentsPanel() {
        guard let p = views["ComponentsPanel"], !p.isHidden else { return }
        p.isHidden = true
        let h = p.frame.height
        view.autoresizesSubviews = false
        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height - h))
        view.autoresizesSubviews = true
    }

    /// 子の表示/非表示 (VCL の Visible と同じ)
    func setVisible(_ n: String, _ v: Bool) { views[n]?.isHidden = !v }
    func setEnabled(_ n: String, _ e: Bool) {
        guard let v = views[n] else { return }
        if let c = v as? NSControl { c.isEnabled = e }
        else if let nf = v as? NumberField { nf.isEnabled = e }
        else if let s = v as? NSScrollView, let t = s.documentView as? NSTextView { t.isEditable = e }
    }

    private func frame(_ o: DFMObject) -> NSRect {
        NSRect(x: CGFloat(o.int("Left") ?? 0), y: CGFloat(o.int("Top") ?? 0),
               width: CGFloat(o.int("Width") ?? 100), height: CGFloat(o.int("Height") ?? 21))
    }

    private func autoresize(_ o: DFMObject) -> NSView.AutoresizingMask {
        if let a = o.str("Align") {
            switch a {
            case "alClient": return [.width, .height]
            case "alTop": return [.width]
            case "alBottom": return [.width, .minYMargin]
            case "alLeft": return [.height]
            case "alRight": return [.minXMargin, .height]
            default: break
            }
        }
        let a = Set(o.props["Anchors"]?.strings ?? ["akLeft", "akTop"])
        var m: NSView.AutoresizingMask = []
        if a.contains("akLeft") && a.contains("akRight") { m.insert(.width) }
        else if a.contains("akRight") { m.insert(.minXMargin) }
        if a.contains("akTop") && a.contains("akBottom") { m.insert(.height) }
        else if a.contains("akBottom") { m.insert(.minYMargin) }
        return m
    }

    private func build(_ o: DFMObject, into parent: NSView) {
        objects[o.name] = o
        let cls = o.className
        // 画面に出ないもの
        if ["TActionList", "TAction", "TPopupMenu", "TMenuItem", "TPngImageList", "TImageList", "TTimer", "TOpenDialog",
            "TSaveDialog", "TTBXPopupMenu", "TTBXItem", "TTBXSeparatorItem", "TTBXSubmenuItem", "TOpenDialogEx"].contains(cls) { return }
        var v: NSView
        let f = frame(o)
        switch cls {
        case "TLabel", "TStaticText":
            let cap = text(o, "Caption") ?? ""
            let l = NSTextField(labelWithString: cap == o.name ? "" : cap)
            l.font = DFMForm.font
            if o.bool("WordWrap") == true { l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0; l.cell?.wraps = true }
            else { l.lineBreakMode = .byTruncatingTail }
            if o.str("Alignment") == "taRightJustify" { l.alignment = .right }
            // & をそのまま出す (訳があれば訳)
            if o.bool("ShowAccelChar") == false, cap != o.name { l.stringValue = translations.get(section, o.path + ".Caption") ?? o.str("Caption") ?? "" }
            v = l
        case "TEdit", "TPasswordEdit":
            let pw = o.str("PasswordChar") != nil || cls == "TPasswordEdit" || o.name.lowercased().contains("password") && !o.name.hasSuffix("View")
            let t: NSTextField = pw ? NSSecureTextField() : NSTextField()
            t.font = DFMForm.font
            t.stringValue = DFMForm.designText(o)
            if o.bool("ReadOnly") == true { t.isEditable = false; t.drawsBackground = false; t.isBezeled = false }
            v = t
        case "TUpDownEdit":
            let n = NumberField()
            n.minValue = Double(o.int("MinValue") ?? 0)
            n.maxValue = Double(o.int("MaxValue") ?? 999999)
            n.increment = Double(o.int("Increment") ?? 1)
            v = n
        case "TFilenameEdit", "TDirectoryEdit", "TComboEdit":
            let t = BrowseField()
            t.directory = cls == "TDirectoryEdit"
            if let bc = o.str("ButtonCaption") { t.button.title = bc }
            t.stringValue = DFMForm.designText(o)
            v = t
        case "TMemo", "TRichEdit":
            let s = NSScrollView()
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            let tv = NSTextView()
            tv.font = cls == "TMemo" && o.str("Font.Name")?.contains("Courier") == true ? .monospacedSystemFont(ofSize: 12, weight: .regular) : DFMForm.font
            tv.isRichText = false
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            let lines = o.props["Lines.Strings"]?.strings ?? []
            tv.string = lines == [o.name] ? "" : lines.joined(separator: "\n")
            if o.bool("ReadOnly") == true { tv.isEditable = false }
            s.documentView = tv
            v = s
        case "TComboBox", "THistoryComboBox":
            if o.str("Style") == "csDropDownList" {
                let p = NSPopUpButton()
                p.font = DFMForm.font
                p.addItems(withTitles: items(o))
                v = p
            } else {
                let c = NSComboBox()
                c.font = DFMForm.font
                c.addItems(withObjectValues: items(o))
                c.stringValue = DFMForm.designText(o)
                v = c
            }
        case "TCheckBox":
            let b = NSButton(checkboxWithTitle: text(o, "Caption") ?? "", target: nil, action: nil)
            b.font = DFMForm.font
            b.state = o.bool("Checked") == true ? .on : .off
            if o.str("State") == "cbGrayed" { b.allowsMixedState = true; b.state = .mixed }
            if o.bool("AllowGrayed") == true { b.allowsMixedState = true }
            v = b
        case "TRadioButton":
            let b = NSButton(radioButtonWithTitle: text(o, "Caption") ?? "", target: self, action: #selector(DFMForm.radioClicked(_:)))
            b.font = DFMForm.font
            b.state = o.bool("Checked") == true ? .on : .off
            v = b
        case "TButton", "TBitBtn", "TSpeedButton":
            let b = NSButton(title: text(o, "Caption") ?? "", target: nil, action: nil)
            b.bezelStyle = .rounded
            b.font = DFMForm.font
            if o.bool("Default") == true { b.keyEquivalent = "\r" }
            if o.bool("Cancel") == true { b.keyEquivalent = "\u{1b}" }
            if let mr = o.str("ModalResult") { b.tag = DFMForm.modalTag(mr) }
            v = b
        case "TGroupBox":
            let g = GroupBoxView(frame: f)
            g.title = text(o, "Caption") ?? ""
            v = g
        case "TPageControl":
            let t = NSTabView(frame: f)
            t.font = DFMForm.font
            let sheets = o.children.filter { $0.className == "TTabSheet" }
            let tabless = sheets.allSatisfy { $0.bool("TabVisible") == false }
            t.tabViewType = tabless ? .noTabsNoBorder : .topTabsBezelBorder
            v = t
            for s in sheets {
                objects[s.name] = s
                let item = NSTabViewItem(identifier: s.name)
                item.label = text(s, "Caption") ?? s.name
                // タブの中の座標: VCL は TabSheet の左上から
                let content = FlippedView(frame: NSRect(origin: .zero, size: f.size))
                item.view = content
                t.addTabViewItem(item)
                tabItems[s.name] = item
                views[s.name] = content
                for c in s.children { build(c, into: content) }
            }
        case "TTreeView":
            let s = NSScrollView()
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            let ov = TreeOutlineView()
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
            col.width = f.width - 4
            ov.addTableColumn(col)
            ov.outlineTableColumn = col
            ov.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            ov.headerView = nil
            ov.rowHeight = 18
            ov.showButtons = o.bool("ShowButtons") != false
            ov.showRoot = o.bool("ShowRoot") != false
            if let ind = o.int("Indent") { ov.indentationPerLevel = CGFloat(ind) }
            ov.nodes = TreeNodeData.parse(o.props["Items.NodeData"]?.data ?? Data())
            s.documentView = ov
            v = s
        case "TListView", "TIEListView", "TDirView", "TUnixDirView":
            let s = NSScrollView()
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            let tv = NSTableView()
            if case .collection(let cols)? = o.props["Columns"] {
                for (i, c) in cols.enumerated() {
                    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                    // JP.ini では列は "<名前>.item0.Caption" の形
                    col.title = (translations.get(section, o.path + ".item\(i).Caption") ?? translations.get(section, o.path + ".Columns.\(i).Caption")).map(Translations.clean) ?? (c["Caption"]?.string ?? "")
                    col.width = CGFloat(c["Width"]?.int ?? 100)
                    tv.addTableColumn(col)
                }
            }
            if tv.tableColumns.isEmpty { tv.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("0"))); tv.headerView = nil }
            if o.bool("ShowColumnHeaders") == false { tv.headerView = nil }
            // 列が 1 つで幅の指定が無い (AutoSize) ときは全体の幅
            if tv.tableColumns.count == 1, case .collection(let cols)? = o.props["Columns"], cols.first?["Width"] == nil {
                tv.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
                tv.tableColumns[0].width = f.width - 4
            }
            s.documentView = tv
            v = s
        case "TTrackBar":
            let sl = NSSlider()
            sl.minValue = Double(o.int("Min") ?? 0)
            sl.maxValue = Double(o.int("Max") ?? 10)
            v = sl
        case "TProgressBar":
            let p = NSProgressIndicator()
            p.style = .bar
            p.isIndeterminate = false
            p.minValue = 0; p.maxValue = 100
            v = p
        case "TBevel":
            let b = NSBox()
            b.boxType = .separator
            v = b
        case "TImage", "TPaintBox", "TPathLabel":
            if cls == "TPathLabel" {
                let l = NSTextField(labelWithString: "")
                l.font = DFMForm.font
                l.lineBreakMode = .byTruncatingMiddle
                v = l
            } else {
                v = NSImageView()
            }
        default:
            // TPanel など: 入れ物
            v = FlippedView(frame: f)
        }
        v.frame = f
        // TLabel は既定で文字に合わせて大きさが変わる (AutoSize)
        if let l = v as? NSTextField, cls == "TLabel" || cls == "TStaticText", o.bool("AutoSize") != false, o.bool("WordWrap") != true {
            let w = ceil(l.cell?.cellSize.width ?? f.width) + 2
            if o.str("Alignment") == "taRightJustify" { l.frame.origin.x = f.maxX - w }
            l.frame.size.width = w
        }
        v.autoresizingMask = autoresize(o)
        if o.bool("Visible") == false { v.isHidden = true }
        if o.bool("Enabled") == false, let c = v as? NSControl { c.isEnabled = false }
        if let hint = text(o, "Hint"), !hint.isEmpty, o.bool("ShowHint") != false { v.toolTip = hint }
        parent.addSubview(v)
        views[o.name] = v
        if cls != "TPageControl" {
            for c in o.children { build(c, into: v) }
        }
    }

    /// 設計時の既定の文字 (コントロールの名前) は消す
    static func designText(_ o: DFMObject) -> String {
        let t = o.str("Text") ?? ""
        return t == o.name ? "" : t
    }

    static func modalTag(_ s: String) -> Int {
        switch s { case "mrOk": return 1; case "mrCancel": return 2; case "mrYes": return 6; case "mrNo": return 7; case "mrAll": return 8; default: return 0 }
    }

    /// 同じ入れ物の中のラジオボタンは 1 つだけ選ばれる (AppKit も同じだが、念のため)
    @objc func radioClicked(_ sender: NSButton) {
        for case let b as NSButton in sender.superview?.subviews ?? [] where b !== sender {
            if b.cell?.isKind(of: NSButtonCell.self) == true, (b.cell as? NSButtonCell)?.title != nil, b.action == #selector(radioClicked(_:)) {
                b.state = .off
            }
        }
        radioChanged?(sender)
    }
    var radioChanged: ((NSButton) -> Void)?

    /// ラジオ・チェックボックス・選択肢が変わったときに呼ぶ (画面の有効/無効の切り替えなど)
    func onChange(_ names: [String], _ f: @escaping () -> Void) {
        let t = ClosureTarget(f)
        changeTargets.append(t)
        for n in names {
            guard let v = views[n] else { continue }
            if let b = v as? NSButton, b.action == #selector(radioClicked(_:)) {
                let prev = radioChanged
                radioChanged = { x in prev?(x); if x === b { f() } }
            } else if let c = v as? NSControl {
                c.target = t; c.action = #selector(ClosureTarget.fire)
            } else if let nf = v as? NumberField {
                nf.onChange = f
            }
        }
    }
    private var changeTargets: [ClosureTarget] = []

    /// 画面をモーダルなウインドウとして出す。押されたボタンの名前を返す
    func runModal(title: String? = nil, parent: NSWindow? = nil, resizable: Bool = false) -> String? {
        let w = NSPanel(contentRect: view.frame, styleMask: resizable ? [.titled, .closable, .resizable] : [.titled, .closable], backing: .buffered, defer: false)
        w.title = title ?? caption
        w.contentView = view
        if let mw = root.int("Constraints.MinWidth"), let mh = root.int("Constraints.MinHeight") {
            w.contentMinSize = NSSize(width: mw, height: mh)
        } else {
            w.contentMinSize = view.frame.size
        }
        var result: String?
        let runner = ModalRunner(window: w) { result = $0 }
        for (name, v) in views {
            guard let b = v as? NSButton, b.tag != 0 || b.keyEquivalent == "\r" || b.keyEquivalent == "\u{1b}" else { continue }
            if b.target == nil && b.action == nil {
                b.target = runner
                b.action = #selector(ModalRunner.press(_:))
                b.identifier = NSUserInterfaceItemIdentifier(name)
            }
        }
        modalRunner = runner
        w.center()
        NSApp.runModal(for: w)
        w.orderOut(nil)
        modalRunner = nil
        return result
    }
    private var modalRunner: ModalRunner?

    /// runModal 中に、コードから閉じる
    func endModal(_ name: String?) { modalRunner?.finish(name) }
}

final class ModalRunner: NSObject, NSWindowDelegate {
    let window: NSWindow
    let done: (String?) -> Void
    /// 押されたボタンで閉じてよいか (入力の確認など)
    var shouldClose: ((String) -> Bool)?
    init(window: NSWindow, done: @escaping (String?) -> Void) {
        self.window = window; self.done = done
        super.init()
        window.delegate = self
    }
    @objc func press(_ b: NSButton) { finish(b.identifier?.rawValue) }
    func finish(_ name: String?) {
        done(name)
        NSApp.stopModal()
    }
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { done(nil); NSApp.stopModal() }
    }
}

/// 数字の欄と上下の矢印 (VCL の TUpDownEdit)
final class NumberField: FlippedView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    var minValue: Double = 0 { didSet { stepper.minValue = minValue } }
    var maxValue: Double = 999999 { didSet { stepper.maxValue = maxValue } }
    var increment: Double = 1 { didSet { stepper.increment = increment } }
    var onChange: (() -> Void)?
    var isEnabled = true { didSet { field.isEnabled = isEnabled; stepper.isEnabled = isEnabled } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = DFMForm.font
        field.delegate = self
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        addSubview(field)
        addSubview(stepper)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }
    override var frame: NSRect { didSet { layoutParts() } }
    private func layoutParts() {
        field.frame = NSRect(x: 0, y: 0, width: max(10, bounds.width - 17), height: bounds.height)
        stepper.frame = NSRect(x: bounds.width - 15, y: (bounds.height - 22) / 2, width: 15, height: 22)
    }

    var value: Int {
        get { Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? Int(stepper.doubleValue) }
        set { field.stringValue = String(newValue); stepper.doubleValue = Double(newValue) }
    }
    @objc func stepped(_ s: NSStepper) { field.stringValue = String(Int(s.doubleValue)); onChange?() }
    func controlTextDidChange(_ obj: Notification) {
        if let v = Double(field.stringValue) { stepper.doubleValue = v }
        onChange?()
    }
}

/// 参照ボタン付きの欄 (TFilenameEdit / TDirectoryEdit)
final class BrowseField: FlippedView {
    let field = NSTextField()
    let button = NSButton(title: "…", target: nil, action: nil)
    var directory = false
    var onBrowse: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = DFMForm.font
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(browse(_:))
        addSubview(field)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var frame: NSRect { didSet { layoutParts() } }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); layoutParts() }
    private func layoutParts() {
        field.frame = NSRect(x: 0, y: 0, width: max(10, bounds.width - 34), height: bounds.height)
        button.frame = NSRect(x: bounds.width - 32, y: -2, width: 34, height: bounds.height + 4)
    }
    var stringValue: String { get { field.stringValue } set { field.stringValue = newValue } }

    @objc func browse(_ sender: Any?) {
        if let f = onBrowse { f(); return }
        let o = NSOpenPanel()
        o.canChooseDirectories = directory
        o.canChooseFiles = !directory
        o.showsHiddenFiles = true
        if !field.stringValue.isEmpty {
            o.directoryURL = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        if o.runModal() == .OK, let u = o.url { field.stringValue = u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    }
}

/// TTreeView の Items.NodeData (VCL の TTreeNodes のバイナリ形式) の 1 項目
struct TreeNodeData {
    var text: String
    var imageIndex: Int
    /// WinSCP は SelectedIndex で TTabSheet の Tag と対応させている (環境設定の左のツリー)
    var selectedIndex: Int
    var children: [TreeNodeData] = []

    /// 形式: 版 (1 バイト)、最上位の数 (4)、各項目 = 大きさ (4、自分を除く)、ImageIndex, SelectedIndex,
    /// StateIndex, OverlayIndex (各 4)、Data (8)、子の数 (4)、Enabled (1)、文字数 (1)、文字 (UTF-16)、子…
    static func parse(_ d: Data) -> [TreeNodeData] {
        let b = [UInt8](d)
        guard b.count >= 5 else { return [] }
        func i32(_ p: Int) -> Int {
            guard p >= 0, p + 4 <= b.count else { return 0 }
            return Int(Int32(bitPattern: UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24))
        }
        var p = 5
        func node() -> TreeNodeData? {
            let size = i32(p)
            guard size >= 30, p + 4 + size <= b.count else { return nil }
            let img = i32(p + 4), sel = i32(p + 8), count = i32(p + 28)
            let len = Int(b[p + 33])
            var units: [UInt16] = []
            for k in 0..<len where p + 35 + 2 * k < b.count { units.append(UInt16(b[p + 34 + 2 * k]) | UInt16(b[p + 35 + 2 * k]) << 8) }
            var text = String(decoding: units, as: UTF16.self)
            // 文字の後ろに "X" が付いている (VCL の形式)
            if text.hasSuffix("X") { text.removeLast() }
            p += 4 + size
            var n = TreeNodeData(text: text, imageIndex: img, selectedIndex: sel)
            for _ in 0..<max(0, count) { if let c = node() { n.children.append(c) } }
            return n
        }
        var out: [TreeNodeData] = []
        for _ in 0..<max(0, i32(1)) { if let n = node() { out.append(n) } }
        return out
    }
}

/// TTreeView (ShowButtons / ShowRoot / Indent を VCL と同じに)
final class TreeOutlineView: NSOutlineView {
    var showButtons = true
    var showRoot = true
    /// .dfm に書かれた項目 (データソースは使う側が用意する)
    var nodes: [TreeNodeData] = []

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        showButtons ? super.frameOfOutlineCell(atRow: row) : .zero
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        guard !showButtons, column == 0 else { return r }
        // 開閉の三角の分を詰める。ShowRoot = False なら最上位は左端から
        let level = CGFloat(self.level(forRow: row) + (showRoot ? 1 : 0))
        let x = level * indentationPerLevel + 2
        r.size.width += r.origin.x - x
        r.origin.x = x
        return r
    }
}
