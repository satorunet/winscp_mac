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
