import XCTest
@testable import ScpCore

final class ScpCoreTests: XCTestCase {
    /// macOS 付属の sftp-server を直接動かして SFTP の読み書きを確かめる
    func testSFTPAgainstLocalServer() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        let c = try SFTPClient.start(process: p)
        defer { c.close() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scpcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = try c.realpath(tmp.path)

        // 大きめのファイル (窓をまたぐように) を上げて下ろす
        var bytes = [UInt8](repeating: 0, count: 3_000_123)
        for i in bytes.indices { bytes[i] = UInt8((i * 7 + i / 255) & 0xff) }
        let src = tmp.appendingPathComponent("src.bin")
        try Data(bytes).write(to: src)
        try c.makeDirectory(base + "/sub dir")
        var last: UInt64 = 0
        try c.upload(src, to: base + "/sub dir/日本語.bin") { last = $0; return true }
        XCTAssertEqual(last, UInt64(bytes.count))
        let back = tmp.appendingPathComponent("back.bin")
        try c.download(base + "/sub dir/日本語.bin", to: back, offset: 0) { _ in true }
        XCTAssertEqual(try Data(contentsOf: back), Data(bytes))

        // 途中から (レジューム)
        try Data(bytes[0..<1000]).write(to: back)
        try c.download(base + "/sub dir/日本語.bin", to: back, offset: 1000) { _ in true }
        XCTAssertEqual(try Data(contentsOf: back), Data(bytes))

        // 一覧・属性・名前変更・削除
        let list = try c.list(base + "/sub dir")
        XCTAssertEqual(list.map(\.name), ["日本語.bin"])
        XCTAssertEqual(list[0].size, UInt64(bytes.count))
        XCTAssertFalse(list[0].owner.isEmpty)
        try c.setPermissions(base + "/sub dir/日本語.bin", 0o640)
        let d = Date(timeIntervalSince1970: 1_600_000_000)
        try c.setModificationTime(base + "/sub dir/日本語.bin", d)
        let st = try c.stat(base + "/sub dir/日本語.bin")
        XCTAssertEqual(st.permissions, 0o640)
        XCTAssertEqual(st.mtime, d)
        try FileManager.default.createSymbolicLink(atPath: tmp.path + "/link", withDestinationPath: tmp.path + "/sub dir")
        let top = try c.list(base)
        let link = top.first { $0.name == "link" }
        XCTAssertEqual(link?.isSymlink, true)
        XCTAssertEqual(link?.isDirectory, true)
        try c.rename(base + "/sub dir/日本語.bin", to: base + "/sub dir/b.bin")
        // posix-rename は上書きできる
        try c.upload(src, to: base + "/sub dir/c.bin") { _ in true }
        try c.rename(base + "/sub dir/c.bin", to: base + "/sub dir/b.bin")
        XCTAssertEqual(try c.list(base + "/sub dir").map(\.name), ["b.bin"])
        try c.removeFile(base + "/sub dir/b.bin")
        try c.removeDirectory(base + "/sub dir")
        XCTAssertThrowsError(try c.stat(base + "/sub dir"))

        // 中止
        XCTAssertThrowsError(try c.upload(src, to: base + "/x.bin") { $0 < 100_000 }) { e in
            XCTAssertTrue((e as? RemoteError)?.isCancelled ?? false)
        }
        // 中止の後も使える
        XCTAssertNoThrow(try c.list(base))
    }

    /// SCP モード (シェルコマンドと scp -t / -f) をこの Mac のシェルで確かめる
    func testSCPWithLocalShell() throws {
        let c = SCPClient(localShell: ())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = tmp.path
        var bytes = [UInt8](repeating: 0, count: 1_234_567)
        for i in bytes.indices { bytes[i] = UInt8(i % 251) }
        let src = tmp.appendingPathComponent("src.bin")
        try Data(bytes).write(to: src)
        try c.makeDirectory(base + "/d i r")
        try c.upload(src, to: base + "/d i r/it's 日本.bin") { _ in true }
        let back = tmp.appendingPathComponent("back.bin")
        var last: UInt64 = 0
        try c.download(base + "/d i r/it's 日本.bin", to: back, offset: 0) { last = $0; return true }
        XCTAssertEqual(last, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: back), Data(bytes))
        let l = try c.list(base + "/d i r")
        XCTAssertEqual(l.map(\.name), ["it's 日本.bin"])
        XCTAssertEqual(l.first?.size, UInt64(bytes.count))
        try c.setPermissions(base + "/d i r/it's 日本.bin", 0o600)
        let d = Date(timeIntervalSince1970: 1_600_000_020)
        try c.setModificationTime(base + "/d i r/it's 日本.bin", d)
        let st = try c.stat(base + "/d i r/it's 日本.bin")
        XCTAssertEqual(st.permissions, 0o600)
        try c.rename(base + "/d i r/it's 日本.bin", to: base + "/d i r/x.bin")
        XCTAssertEqual(try c.list(base + "/d i r").map(\.name), ["x.bin"])
        XCTAssertTrue(try c.list(base).contains { $0.name == "d i r" && $0.isDirectory })
        XCTAssertEqual(try c.runCommand("echo hi", in: base + "/d i r"), "hi\n")
        XCTAssertThrowsError(try c.download(base + "/nope", to: back, offset: 0) { _ in true })
        try c.removeFile(base + "/d i r/x.bin")
        try c.removeDirectory(base + "/d i r")
        XCTAssertTrue(try c.list(base).allSatisfy { $0.name != "d i r" })
    }

    func testUnixListParser() {
        let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let text = """
        total 12
        drwxr-xr-x  5 user  staff   160 Nov 20 10:30 .
        drwxr-xr-x  5 user  staff   160 Nov 20 10:30 ..
        -rw-r--r--  1 user  staff  1234 Dec 24 09:15 my file.txt
        lrwxr-xr-x  1 root  wheel    11 Jan  1  2020 link -> /etc/hosts
        drwsr-sr-t  2 www   www    4096 Mar  3 23:59 dir
        -rw-r--r-- 1 u g 99 2025-11-20 13:45:10 +0900 iso name.txt
        """
        let l = ListParser.parseUnixList(text, now: now)
        XCTAssertEqual(l.map(\.name), ["my file.txt", "link", "dir", "iso name.txt"])
        XCTAssertEqual(l[0].size, 1234)
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.year, from: l[0].mtime!), 2025)   // 12 月は去年
        XCTAssertEqual(l[1].linkTarget, "/etc/hosts")
        XCTAssertTrue(l[1].isSymlink)
        XCTAssertEqual(l[2].permissions, 0o7755)
        XCTAssertEqual(l[2].rightsString, "rwsr-sr-t")
        XCTAssertTrue(l[2].isDirectory)
        XCTAssertEqual(l[3].mtime, ISO8601DateFormatter().date(from: "2025-11-20T04:45:10Z"))
        XCTAssertEqual(l[3].owner, "u")

        let m = ListParser.parseMLSDLine("type=file;size=42;modify=20251120134500;UNIX.mode=0644; a b.txt")
        XCTAssertEqual(m?.name, "a b.txt")
        XCTAssertEqual(m?.size, 42)
        XCTAssertEqual(m?.permissions, 0o644)
        XCTAssertNil(ListParser.parseMLSDLine("type=cdir; ."))
        XCTAssertEqual(ListParser.parseMLSDLine("type=dir;modify=20200101000000; d")?.isDirectory, true)
    }

    func testRemotePath() {
        XCTAssertEqual(RemotePath.parent("/a/b/"), "/a")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.join("/", "x"), "/x")
        XCTAssertEqual(RemotePath.normalize("/a/./b/../c"), "/a/c")
        XCTAssertEqual(RemotePath.name("/a/b"), "b")
    }

    func testWinSCPIni() {
        let enc = WinSCPIni.encryptPassword("p@ss 日本", key: "bobexample.com")
        XCTAssertEqual(WinSCPIni.decryptPassword(enc, key: "bobexample.com"), "p@ss 日本")
        XCTAssertNil(WinSCPIni.decryptPassword(enc, key: "other"))
        let ini = """
        [Configuration\\Interface]
        Foo=1
        [Sessions\\Default%20Settings]
        HostName=
        [Sessions\\Work/web%20server]
        HostName=example.com
        UserName=bob
        PortNumber=2222
        Password=\(WinSCPIni.encryptPassword("secret", key: "bobexample.com"))
        RemoteDirectory=/var/www
        [Sessions\\ftp]
        HostName=ftp.example.com
        FSProtocol=5
        Ftps=3
        [Sessions\\s3]
        HostName=s3.amazonaws.com
        FSProtocol=7
        """
        let r = WinSCPIni.read(Data(ini.utf8))
        XCTAssertEqual(r.sites.count, 2)
        XCTAssertEqual(r.sites[0].path, "Work/web server")
        XCTAssertEqual(r.sites[0].port, 2222)
        XCTAssertEqual(r.sites[0].password, "secret")
        XCTAssertEqual(r.sites[0].proto, .sftp)
        XCTAssertEqual(r.sites[0].remoteDirectory, "/var/www")
        XCTAssertEqual(r.sites[1].proto, .ftp)
        XCTAssertEqual(r.sites[1].ftpSecurity, .explicitTLS)
        XCTAssertEqual(r.sites[1].port, 21)
        XCTAssertEqual(r.notes.count, 1)
        // Windows の改行 (CRLF) でも読める
        XCTAssertEqual(WinSCPIni.read(Data(ini.replacingOccurrences(of: "\n", with: "\r\n").utf8)).sites, r.sites)
    }

    func testWinSCPRegAndExport() {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Configuration\\Interface]
        "Foo"=dword:00000001

        [HKEY_CURRENT_USER\\Software\\Martin Prikryl\\WinSCP 2\\Sessions\\My%20Folder/%E6%97%A5%E6%9C%AC]
        "HostName"="example.jp"
        "UserName"="taro"
        "PortNumber"=dword:00000016
        "FSProtocol"=dword:00000005
        "Ftps"=dword:00000001
        "Password"="\(WinSCPIni.encryptPassword("pw", key: "taroexample.jp"))"
        "RemoteDirectory"="/home/taro"
        """
        var d = Data([0xFF, 0xFE])
        d.append(reg.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf16LittleEndian)!)
        let r = WinSCPIni.read(d)
        XCTAssertEqual(r.sites.count, 1)
        let s = r.sites[0]
        XCTAssertEqual(s.path, "My Folder/日本")
        XCTAssertEqual(s.port, 22)
        XCTAssertEqual(s.proto, .ftp)
        XCTAssertEqual(s.ftpSecurity, .implicitTLS)
        XCTAssertEqual(s.password, "pw")
        XCTAssertEqual(s.remoteDirectory, "/home/taro")
        // 書き出して読み戻すと同じ
        let again = WinSCPIni.read(WinSCPIni.write(r.sites))
        XCTAssertEqual(again.sites, r.sites)
        XCTAssertTrue(String(decoding: WinSCPIni.write(r.sites), as: UTF8.self).contains("[Sessions\\My%20Folder/%E6%97%A5%E6%9C%AC]"))
    }

    func testAskpassClassify() {
        XCTAssertEqual(AskpassServer.classify("bob@host's password: "), .password)
        XCTAssertEqual(AskpassServer.classify("Are you sure you want to continue connecting (yes/no/[fingerprint])?"), .hostKey)
    }
}
