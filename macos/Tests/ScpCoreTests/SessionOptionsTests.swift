import XCTest
@testable import ScpCore

/// WinSCP の「高度なサイトの設定」(WinSCP.ini のキー) → ssh の引数 / FTP の設定
final class SessionOptionsTests: XCTestCase {
    let ciphers: Set<String> = ["3des-cbc", "aes128-cbc", "aes192-cbc", "aes256-cbc", "aes128-ctr", "aes192-ctr", "aes256-ctr",
                                "aes128-gcm@openssh.com", "aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"]
    let kex: Set<String> = ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1", "diffie-hellman-group14-sha256",
                            "diffie-hellman-group16-sha512", "diffie-hellman-group18-sha512", "diffie-hellman-group-exchange-sha1",
                            "diffie-hellman-group-exchange-sha256", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
                            "curve25519-sha256", "curve25519-sha256@libssh.org", "sntrup761x25519-sha512@openssh.com"]

    func ssh(_ v: [String: String], host: String = "example.com", port: Int = 22) -> SSHOptionSet {
        SessionOptions.ssh(WinSCPSessionData(v), host: host, port: port, supportedCiphers: ciphers, supportedKex: kex)
    }
    /// -o の値を "名前" → "値" にする
    func opts(_ a: [String]) -> [String: String] {
        var r: [String: String] = [:]
        var i = 0
        while i < a.count {
            if a[i] == "-o", i + 1 < a.count, let eq = a[i + 1].firstIndex(of: "=") {
                r[String(a[i + 1][..<eq])] = String(a[i + 1][a[i + 1].index(after: eq)...])
                i += 2
            } else { i += 1 }
        }
        return r
    }

    func testDefaults() {
        let o = ssh([:])
        // WinSCP の既定: 接続の保持はオフ、タイムアウト 15 秒、GSSAPI はあり
        XCTAssertEqual(o.args, ["-o", "ServerAliveInterval=0", "-o", "ConnectTimeout=15", "-o", "GSSAPIAuthentication=yes"])
        XCTAssertFalse(o.forwardAgent)
        XCTAssertTrue(o.scpFallback)
        XCTAssertEqual(o.sftpServer, "")
    }

    func testConnectionAndAuth() {
        let o = ssh(["Compression": "1", "PingType": "2", "PingInterval": "1", "PingIntervalSecs": "15", "Timeout": "40",
                     "AddressFamily": "1", "TryAgent": "1", "AgentFwd": "1", "AuthKI": "0", "AuthGSSAPI": "1",
                     "GSSAPIFwdTGT": "1", "DetachedCertificate": "~/.ssh/id_ed25519-cert.pub", "FSProtocol": "2"])
        let m = opts(o.args)
        XCTAssertEqual(m["Compression"], "yes")
        XCTAssertEqual(m["ServerAliveInterval"], "75")
        XCTAssertEqual(m["ConnectTimeout"], "40")
        XCTAssertEqual(m["AddressFamily"], "inet")
        XCTAssertEqual(m["ForwardAgent"], "yes")
        XCTAssertEqual(m["KbdInteractiveAuthentication"], "no")
        XCTAssertEqual(m["GSSAPIDelegateCredentials"], "yes")
        XCTAssertEqual(m["CertificateFile"], NSHomeDirectory() + "/.ssh/id_ed25519-cert.pub")
        XCTAssertNil(m["IdentityAgent"])
        XCTAssertTrue(o.forwardAgent)
        XCTAssertFalse(o.scpFallback)

        let n = opts(ssh(["TryAgent": "0", "AgentFwd": "1", "AuthGSSAPI": "0", "AddressFamily": "2", "PingType": "1"]).args)
        XCTAssertEqual(n["IdentityAgent"], "none")
        XCTAssertNil(n["ForwardAgent"])   // エージェントを使わないなら転送もしない (WinSCP と同じく無効)
        XCTAssertEqual(n["GSSAPIAuthentication"], "no")
        XCTAssertEqual(n["AddressFamily"], "inet6")
        XCTAssertEqual(n["ServerAliveInterval"], "30")
    }

    func testAlgorithmOrder() {
        // 保存された並びに足りないものは、WinSCP の SetAlgoList と同じ位置に補う
        XCTAssertEqual(WinSCPSessionData([:]).ciphers, WinSCPSessionData.defaultCiphers)
        XCTAssertEqual(WinSCPSessionData(["Cipher": "chacha20,aes"]).ciphers,
                       ["chacha20", "aes", "aesgcm", "3des", "WARN", "des", "blowfish", "arcfour"])
        XCTAssertEqual(WinSCPSessionData(["Cipher": "aes,chacha20,aesgcm,3des,WARN,des,blowfish,arcfour"]).ciphers,
                       WinSCPSessionData.defaultCiphers)

        // 既定の並びなら Ciphers は渡さない (OpenSSH の既定のまま)
        XCTAssertNil(opts(ssh(["Cipher": "aes,chacha20,aesgcm,3des,WARN,des,blowfish,arcfour"]).args)["Ciphers"])
        // 警告レベルより下は使わない、ssh が知らないものは除く
        let c = opts(ssh(["Cipher": "chacha20,aesgcm,WARN,aes,3des,des,blowfish,arcfour"]).args)["Ciphers"]
        XCTAssertEqual(c, "chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes256-gcm@openssh.com")
        let k = opts(ssh(["KEX": "ecdh,dh-gex-sha1,WARN,ntru-curve25519,mlkem-curve25519,mlkem-nist,dh-group18-sha512,dh-group17-sha512,dh-group16-sha512,dh-group15-sha512,dh-group14-sha1,rsa,dh-group1-sha1"]).args)["KexAlgorithms"]
        XCTAssertEqual(k, "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group-exchange-sha1")
    }

    func testRekey() {
        XCTAssertNil(opts(ssh([:]).args)["RekeyLimit"])
        XCTAssertEqual(opts(ssh(["RekeyBytes": "512M", "RekeyTime": "30"]).args)["RekeyLimit"], "512M 1800")
        XCTAssertEqual(opts(ssh(["RekeyBytes": "0", "RekeyTime": "0"]).args)["RekeyLimit"], "default none")
    }

    func testProxy() {
        XCTAssertEqual(opts(ssh(["ProxyMethod": "2", "ProxyHost": "socks.local", "ProxyPort": "1080"]).args)["ProxyCommand"],
                       "/usr/bin/nc -X 5 -x socks.local:1080 'example.com' 22")
        XCTAssertEqual(opts(ssh(["ProxyMethod": "1", "ProxyHost": "s", "ProxyPort": "1080"], port: 2222).args)["ProxyCommand"],
                       "/usr/bin/nc -X 4 -x s:1080 'example.com' 2222")
        XCTAssertEqual(opts(ssh(["ProxyMethod": "3", "ProxyHost": "web", "ProxyPort": "8080"]).args)["ProxyCommand"],
                       "/usr/bin/nc -X connect -x web:8080 'example.com' 22")
        // 名前で書かれた ProxyMethod も読める
        XCTAssertEqual(WinSCPSessionData(["ProxyMethod": "SOCKS5"]).proxyMethod, 2)
        // ローカル: パターンを展開し、ssh の % は %% に
        let local = opts(ssh(["ProxyMethod": "5", "ProxyTelnetCommand": "connect-proxy -S %user@%proxyhost:%proxyport %host %port 100%%",
                              "ProxyHost": "gw", "ProxyPort": "1080", "ProxyUsername": "me"]).args)["ProxyCommand"]
        XCTAssertEqual(local, "connect-proxy -S me@gw:1080 example.com 22 100%%")
        // Telnet: 送る文字列は 8 進で printf する
        let tel = opts(ssh(["ProxyMethod": "4", "ProxyHost": "tp", "ProxyPort": "23"]).args)["ProxyCommand"] ?? ""
        XCTAssertTrue(tel.hasPrefix("(printf '\\143\\157\\156"), tel)   // "con..."
        XCTAssertTrue(tel.hasSuffix("; exec cat) | /usr/bin/nc 'tp' 23"), tel)
        XCTAssertEqual(SessionOptions.formatProxyCommand("connect %host %port\\n\\x41", host: "h", port: 22, proxyHost: "p", proxyPort: 1,
                                                         user: "u", password: "pw"), "connect h 22\nA")
    }

    func testTunnel() {
        var d = WinSCPSessionData(["Tunnel": "1", "TunnelHostName": "jump.example.com", "TunnelPortNumber": "2200",
                                   "TunnelUserName": "alice", "TunnelPublicKeyFile": "~/.ssh/jump"])
        d.setPassword("secret", plain: "TunnelPasswordPlain", encrypted: "TunnelPassword", key: "alice" + "jump.example.com")
        XCTAssertEqual(d.tunnelPassword, "secret")
        let pc = opts(SessionOptions.ssh(d, host: "inner", port: 22, supportedCiphers: ciphers, supportedKex: kex).args)["ProxyCommand"] ?? ""
        XCTAssertTrue(pc.hasPrefix("/usr/bin/ssh "), pc)
        XCTAssertTrue(pc.contains("-p 2200 -l 'alice' -i '\(NSHomeDirectory())/.ssh/jump'"), pc)
        XCTAssertTrue(pc.hasSuffix(" -W %h:%p 'jump.example.com'"), pc)
        // トンネルとプロキシ: プロキシは踏み台への接続に使う (%% が二重になる)
        d.values["ProxyMethod"] = "2"
        d.values["ProxyHost"] = "socks"
        d.values["ProxyPort"] = "1080"
        let pc2 = opts(SessionOptions.ssh(d, host: "inner", port: 22, supportedCiphers: ciphers, supportedKex: kex).args)["ProxyCommand"] ?? ""
        XCTAssertTrue(pc2.contains("'-oProxyCommand=/usr/bin/nc -X 5 -x socks:1080 '\\''jump.example.com'\\'' 2200'"), pc2)
    }

    func testValueEncodings() {
        // TimeDifference: TDateTime (日) の double を 16 進で
        var d = WinSCPSessionData()
        d.timeDifferenceMinutes = -90
        XCTAssertEqual(d.values["TimeDifference"]?.count, 16)
        XCTAssertEqual(d.timeDifferenceMinutes, -90)
        XCTAssertEqual(WinSCPSessionData(["TimeDifference": WinSCPSessionData.encodeFloat(1.0 / 24)]).timeDifferenceMinutes, 60)
        XCTAssertEqual(WinSCPSessionData.encodeFloat(1.0), "000000000000F03F")
        XCTAssertFalse(d.timeDifferenceAuto)
        XCTAssertTrue(WinSCPSessionData().timeDifferenceAuto)
        // 接続の保持の間隔
        XCTAssertEqual(WinSCPSessionData().pingInterval, 30)
        d.pingInterval = 125
        XCTAssertEqual(d.values["PingInterval"], "2")
        XCTAssertEqual(d.values["PingIntervalSecs"], "5")
        XCTAssertEqual(d.pingInterval, 125)
        // ProxyDNS は (値 + 2) % 3、Bug は 2 - 値
        XCTAssertEqual(WinSCPSessionData().proxyDNS, .auto)
        XCTAssertEqual(WinSCPSessionData(["ProxyDNS": "2"]).proxyDNS, .on)
        XCTAssertEqual(WinSCPSessionData(["ProxyDNS": "0"]).proxyDNS, .off)
        XCTAssertEqual(WinSCPSessionData(["BugRekey2": "0"]).bug("Rekey2"), .auto)
        XCTAssertEqual(WinSCPSessionData(["BugRekey2": "2"]).bug("Rekey2"), .on)
        XCTAssertEqual(WinSCPSessionData(["FtpUseMlsd": "off"]).autoSwitch("FtpUseMlsd"), .off)
        // プロキシのパスワード (ProxyPasswordEnc は ユーザー名 + ホスト名 で暗号化)
        var p = WinSCPSessionData(["ProxyUsername": "u", "ProxyHost": "h"])
        p.setPassword("pw", plain: "ProxyPassword", encrypted: "ProxyPasswordEnc", key: "uh")
        XCTAssertNotNil(p.values["ProxyPasswordEnc"])
        XCTAssertEqual(p.proxyPassword, "pw")
        XCTAssertEqual(WinSCPSessionData(["ProxyPassword": "plain"]).proxyPassword, "plain")
        // ローカル プロキシは ProxyTelnetCommand に入っている
        let l = WinSCPSessionData(["ProxyMethod": "5", "ProxyTelnetCommand": "cmd"])
        XCTAssertEqual(l.proxyLocalCommand, "cmd")
        XCTAssertEqual(l.proxyTelnetCommand, "connect %host %port\\n")
    }

    func testFTP() {
        let base = FTPClient.Params(host: "ftp.example.com", port: 21, user: "u", password: "p", security: .explicitTLS, passive: true)
        let def = SessionOptions.ftp(WinSCPSessionData(), base)
        XCTAssertEqual(def.timeout, 15)
        XCTAssertEqual(def.useMLSD, .auto)
        XCTAssertEqual(def.minTLS, 12)
        XCTAssertEqual(def.maxTLS, 13)
        XCTAssertTrue(def.tlsSessionReuse)
        XCTAssertNil(def.socksProxy)
        XCTAssertEqual(def.timeDifference, 0)

        let p = SessionOptions.ftp(WinSCPSessionData([
            "Timeout": "60", "FtpUseMlsd": "1", "FtpListAll": "0", "FtpForcePasvIp2": "0", "FtpHost": "0", "FtpAccount": "acct",
            "PostLoginCommands": "SITE UMASK 022\r\nSITE IDLE 600\r\n", "MinTlsVersion": "11", "MaxTlsVersion": "12",
            "SslSessionReuse": "0", "AddressFamily": "2", "ProxyMethod": "2", "ProxyHost": "s", "ProxyPort": "1080",
            "ProxyUsername": "pu", "ProxyPassword": "pp", "TimeDifference": WinSCPSessionData.encodeFloat(2.0 / 24),
            "TimeDifferenceAuto": "0",
        ]), FTPClient.Params(host: "h", passive: false))
        XCTAssertEqual(p.timeout, 60)
        XCTAssertEqual(p.useMLSD, .off)
        XCTAssertEqual(p.listAll, .on)
        XCTAssertEqual(p.forcePasvIP, .on)
        XCTAssertTrue(p.sendHost)
        XCTAssertEqual(p.account, "acct")
        XCTAssertEqual(p.postLoginCommands, ["SITE UMASK 022", "SITE IDLE 600"])
        XCTAssertEqual(p.minTLS, 11)
        XCTAssertEqual(p.maxTLS, 12)
        XCTAssertFalse(p.tlsSessionReuse)
        XCTAssertEqual(p.addressFamily, AF_INET6)
        XCTAssertEqual(p.socksProxy, FTPClient.SOCKSProxy(version: 5, host: "s", port: 1080, user: "pu", password: "pp"))
        XCTAssertTrue(p.passive)   // プロキシ経由ならパッシブ
        XCTAssertEqual(p.timeDifference, 7200)
    }

    /// ssh が実際にこのオプションを受け付けるか (ssh -G で確かめる。接続はしない)
    func testOpenSSHAcceptsOptions() throws {
        let o = SessionOptions.ssh(WinSCPSessionData([
            "Compression": "1", "PingType": "2", "Timeout": "20", "AddressFamily": "1", "TryAgent": "0", "AuthKI": "0",
            "AuthGSSAPI": "1", "GSSAPIFwdTGT": "1", "RekeyBytes": "512M", "RekeyTime": "30",
            "Cipher": "chacha20,aesgcm,aes,WARN", "KEX": "ecdh,ntru-curve25519,dh-gex-sha1,WARN", "ProxyMethod": "2", "ProxyHost": "s",
        ]), host: "example.com", port: 22)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + o.args + ["example.com"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(text.contains("compression yes"))
        XCTAssertTrue(text.contains("serveraliveinterval 30"))
        XCTAssertTrue(text.contains("connecttimeout 20"))
        XCTAssertTrue(text.contains("addressfamily inet"))
        XCTAssertTrue(text.contains("identityagent none"))
        XCTAssertTrue(text.contains("ciphers chacha20-poly1305@openssh.com,aes128-gcm@openssh.com"))
        XCTAssertTrue(text.contains("kexalgorithms curve25519-sha256"))
        XCTAssertTrue(text.contains("rekeylimit 536870912 1800"))
        XCTAssertTrue(text.contains("proxycommand /usr/bin/nc -X 5 -x s:80"))
    }
}
