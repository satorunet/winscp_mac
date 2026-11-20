import XCTest
@testable import ScpCore

/// 日本語のファイル名 (濁点・半濁点、古い文字コード) が化けないこと
final class JapaneseNameTests: XCTestCase {
    /// ディレクトリの中の名前を、Foundation を通さずにバイト列のまま読む (Foundation は NFD に変えてしまう)
    func rawNames(_ dir: String) -> [[UInt8]] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var out: [[UInt8]] = []
        while let e = readdir(d) {
            var nameBytes = e.pointee.d_name
            let n = Int(e.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: &nameBytes) { Array($0.prefix(n)) }
            if bytes != [0x2E] && bytes != [0x2E, 0x2E] { out.append(bytes) }
        }
        return out
    }

    let nfc = "データ ぱぴぷ.txt"   // 合成形
    var nfd: String { nfc.decomposedStringWithCanonicalMapping }

    func testASCIISafeCommandKeepsBytes() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let text = "ダ%s\\n'\"$HOME`x`"
        p.arguments = ["-c", SSHSession.asciiSafe("printf %s " + SSHSession.quote(text))]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(Array(out.fileHandleForReading.readDataToEndOfFile()), Array(text.utf8))
    }

    func testSCPUploadUsesExactBytes() throws {
        let c = SCPClient(localShell: ())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.txt")
        try Data("x".utf8).write(to: src)
        try FileManager.default.createDirectory(atPath: tmp.path + "/up", withIntermediateDirectories: true)
        try c.upload(src, to: tmp.path + "/up/" + nfc) { _ in true }
        XCTAssertEqual(rawNames(tmp.path + "/up"), [Array(nfc.utf8)], "SCP で合成形 (NFC) のまま作られること")
        XCTAssertEqual(try c.list(tmp.path + "/up").map { Array($0.name.utf8) }, [Array(nfc.utf8)])
        try c.rename(tmp.path + "/up/" + nfc, to: tmp.path + "/up/" + nfc + "2")
        XCTAssertEqual(rawNames(tmp.path + "/up"), [Array((nfc + "2").utf8)])
    }

    func testSFTPUploadUsesExactBytesAndLegacyNames() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        let c = try SFTPClient.start(process: p)
        defer { c.close() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src.txt")
        try Data("x".utf8).write(to: src)
        try c.makeDirectory(tmp.path + "/up")
        try c.upload(src, to: tmp.path + "/up/" + nfc) { _ in true }
        XCTAssertEqual(rawNames(tmp.path + "/up"), [Array(nfc.utf8)], "SFTP で合成形 (NFC) のまま作られること")

        // Shift_JIS の名前は読めて、元のバイト列で送り返される
        let sjis = "日本語.txt".data(using: .shiftJIS)!
        let name = c.decodeName(sjis)
        XCTAssertEqual(name, "日本語.txt")
        XCTAssertEqual(c.encodePath("/a/" + name), Data("/a/".utf8) + sjis)
        XCTAssertEqual(c.encodePath("/a/普通.txt"), Data("/a/普通.txt".utf8))
    }

    func testUploadNameNormalization() {
        // アップロード先の名前は Mac の分解形から合成形にする (Transfer.swift と同じ変換)
        XCTAssertEqual(Array(nfd.precomposedStringWithCanonicalMapping.utf8), Array(nfc.utf8))
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8))
    }
}
