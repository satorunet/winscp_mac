import XCTest
@testable import ScpCore

/// 公開テストサーバー (test.rebex.net, 読み取り専用) を使う。WINSCPMAC_LIVE=1 のときだけ
final class LiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WINSCPMAC_LIVE"] == "1")
    }

    func ftp(_ sec: FTPSecurity) throws {
        let c = try FTPClient(.init(host: "test.rebex.net", port: sec == .implicitTLS ? 990 : 21, user: "demo", password: "password", security: sec), certificateHandler: { _, _ in true })
        let t0 = Date()
        c.log = { print(String(format: "%6.2f FTP| ", Date().timeIntervalSince(t0)) + $0.prefix(60)) }
        defer { c.close() }
        XCTAssertEqual(try c.homeDirectory(), "/")
        let l = try c.list("/")
        print(l.map(\.name))
        XCTAssertTrue(l.contains { $0.name == "readme.txt" && !$0.isDirectory && $0.size > 0 })
        XCTAssertTrue(l.contains { $0.name == "pub" && $0.isDirectory })
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rebex-\(UUID().uuidString)")
        try c.download("/readme.txt", to: tmp, offset: 0) { _ in true }
        XCTAssertEqual(try Data(contentsOf: tmp).count, Int(l.first { $0.name == "readme.txt" }!.size))
        XCTAssertGreaterThan(try c.list("/pub/example").count, 3)
        XCTAssertEqual(try c.stat("/readme.txt").size, l.first { $0.name == "readme.txt" }!.size)
    }

    func testFTP() throws { try ftp(.none) }
    func testFTPSExplicit() throws { try ftp(.explicitTLS) }
    func testFTPSImplicit() throws { try ftp(.implicitTLS) }

    static var askpass: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/WinSCPMac").path
    }

    func ssh(_ proto: FileProtocol) throws -> RemoteFileSystem {
        let kh = FileManager.default.temporaryDirectory.appendingPathComponent("kh-live").path
        var prompts: [String] = []
        let fs = try SSHConnector.connect(SSHParams(host: "test.rebex.net", user: "demo", extraArgs: ["-o", "UserKnownHostsFile=\(kh)", "-o", "StrictHostKeyChecking=accept-new"]),
                                          protocol: proto, askpassProgram: LiveTests.askpass) { p, kind in
            prompts.append(p)
            return kind == .password ? "password" : nil
        }
        print("prompts:", prompts)
        return fs
    }

    /// 「高度なサイトの設定」から作った ssh のオプションで接続できること (圧縮・接続の保持・暗号・鍵交換・IPv4)
    func testSSHWithSiteOptions() throws {
        let kh = FileManager.default.temporaryDirectory.appendingPathComponent("kh-live").path
        var params = SSHParams(host: "test.rebex.net", user: "demo", extraArgs: ["-o", "UserKnownHostsFile=\(kh)", "-o", "StrictHostKeyChecking=accept-new"])
        params.apply(SessionOptions.ssh(WinSCPSessionData([
            "Compression": "1", "PingType": "2", "PingIntervalSecs": "10", "Timeout": "20", "AddressFamily": "1",
            "Cipher": "aesgcm,chacha20,aes,WARN", "KEX": "ecdh,dh-gex-sha1,WARN", "RekeyBytes": "256M",
            "TryAgent": "0", "AuthGSSAPI": "0",
        ]), host: "test.rebex.net", port: 22))
        let fs = try SSHConnector.connect(params, protocol: .sftp, askpassProgram: LiveTests.askpass) { _, kind in
            kind == .password ? "password" : nil
        }
        defer { fs.close() }
        XCTAssertTrue(try fs.list("/").contains { $0.name == "readme.txt" })
    }

    /// FTP: MLSD を使わない・LIST -a なし・HOST・タイムアウト・TLS 1.2 以上・ログイン コマンド・IPv4
    func testFTPWithSiteOptions() throws {
        let p = SessionOptions.ftp(WinSCPSessionData([
            "FtpUseMlsd": "1", "FtpListAll": "1", "FtpHost": "0", "Timeout": "20", "MinTlsVersion": "12",
            "PostLoginCommands": "NOOP\r\n", "AddressFamily": "1",
        ]), .init(host: "test.rebex.net", port: 21, user: "demo", password: "password", security: .explicitTLS))
        let c = try FTPClient(p, certificateHandler: { _, _ in true })
        defer { c.close() }
        let l = try c.list("/")
        XCTAssertTrue(l.contains { $0.name == "readme.txt" && !$0.isDirectory })
        try c.keepAlive()

        // 「データ接続に TLS セッション ID を再利用する」をオフにすると、再利用を求めるこのサーバーでは断られる (設定が効いている)
        let q = SessionOptions.ftp(WinSCPSessionData(["SslSessionReuse": "0"]),
                                   .init(host: "test.rebex.net", port: 21, user: "demo", password: "password", security: .explicitTLS))
        let c2 = try FTPClient(q, certificateHandler: { _, _ in true })
        defer { c2.close() }
        XCTAssertThrowsError(try c2.list("/"))
    }

    /// FTP のアクティブ モード (NAT の内側ではサーバーからつなげないので、失敗しても止めない)
    func testFTPActiveMode() throws {
        let c = try FTPClient(.init(host: "test.rebex.net", port: 21, user: "demo", password: "password", passive: false),
                              certificateHandler: { _, _ in true })
        defer { c.close() }
        do {
            let l = try c.list("/")
            XCTAssertTrue(l.contains { $0.name == "readme.txt" })
            print("active mode: OK")
        } catch {
            print("active mode: \(error.localizedDescription) (NAT の内側では通常のこと)")
        }
    }

    func testSFTPOverSSH() throws {
        let fs = try ssh(.sftp)
        defer { fs.close() }
        XCTAssertEqual(try fs.homeDirectory(), "/")
        XCTAssertTrue(try fs.list("/").contains { $0.name == "readme.txt" })
    }

    func testSCP() throws {
        let fs = try ssh(.scp)
        defer { fs.close() }
        print("home:", try fs.homeDirectory())
        let l = try fs.list("/")
        XCTAssertTrue(l.contains { $0.name == "readme.txt" && $0.size == 379 })
        XCTAssertTrue(l.contains { $0.name == "pub" && $0.isDirectory })
        XCTAssertGreaterThan(try fs.list("/pub/example").count, 3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rebex-scp-\(UUID().uuidString)")
        try fs.download("/readme.txt", to: tmp, offset: 0) { _ in true }
        XCTAssertEqual(try Data(contentsOf: tmp).count, 379)
    }
}
