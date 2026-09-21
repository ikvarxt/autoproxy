import XCTest
@testable import AutoProxy

final class VersionTests: XCTestCase {
    func testParsesTagWithPrefix() {
        XCTAssertEqual(Version("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(Version("1.2.3")?.description, "1.2.3")
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(Version("1.2.3-beta"))
        XCTAssertNil(Version("latest"))
        XCTAssertNil(Version(""))
    }

    func testComparesBySegmentNotByString() {
        // 字符串比较会把 0.10.0 判成比 0.9.0 小，那样发到两位数就再也收不到更新
        XCTAssertTrue(Version("0.9.0")! < Version("0.10.0")!)
        XCTAssertTrue(Version("1.0.0")! > Version("0.99.99")!)
    }

    func testMissingSegmentsAreZero() {
        XCTAssertEqual(Version("1.2")!, Version("1.2.0")!)
        XCTAssertTrue(Version("1.2")! < Version("1.2.1")!)
    }
}

final class ReleaseFeedTests: XCTestCase {
    private func feed(tag: String = "v0.4.0",
                      assets: String = #"[{"name":"AutoProxy-0.4.0.zip","browser_download_url":"https://example.com/a.zip"}]"#,
                      extra: String = "") -> Data {
        Data(#"{"tag_name":"\#(tag)"\#(extra),"assets":\#(assets)}"#.utf8)
    }

    func testPicksVersionAndZip() {
        let release = ReleaseFeed.parse(feed())
        XCTAssertEqual(release?.version, Version("0.4.0"))
        XCTAssertEqual(release?.zip.absoluteString, "https://example.com/a.zip")
    }

    func testSkipsDraftAndPrerelease() {
        XCTAssertNil(ReleaseFeed.parse(feed(extra: #","draft":true"#)))
        XCTAssertNil(ReleaseFeed.parse(feed(extra: #","prerelease":true"#)))
    }

    func testIgnoresNonZipAssets() {
        // release 里除了包还挂着 notes、校验和之类的东西，挑错了会下到一个不能装的文件
        let mixed = #"[{"name":"notes.md","browser_download_url":"https://example.com/n.md"},"#
            + #"{"name":"AutoProxy-0.4.0.zip","browser_download_url":"https://example.com/a.zip"}]"#
        XCTAssertEqual(ReleaseFeed.parse(feed(assets: mixed))?.zip.absoluteString, "https://example.com/a.zip")
    }

    func testNoZipMeansNothingToInstall() {
        XCTAssertNil(ReleaseFeed.parse(feed(assets: #"[]"#)))
    }

    func testGarbageIsNotARelease() {
        XCTAssertNil(ReleaseFeed.parse(Data("not json".utf8)))
    }
}

final class InstallerTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 造一个只有 Info.plist 的 .app，打成 zip —— unpack 看的就是这两样东西
    private func packApp(bundleID: String, version: String) throws -> URL {
        let app = sandbox.appendingPathComponent("AutoProxy.app")
        try? FileManager.default.removeItem(at: app)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let zip = sandbox.appendingPathComponent("app.zip")
        try? FileManager.default.removeItem(at: zip)
        XCTAssertTrue(Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path], timeout: 60).ok)
        try FileManager.default.removeItem(at: app)
        return zip
    }

    func testUnpacksMatchingBundle() throws {
        let zip = try packApp(bundleID: AppInfo.bundleID, version: "0.4.0")
        let app = try Installer.unpack(zip: zip, expecting: Version("0.4.0")!)
        XCTAssertEqual(app.lastPathComponent, "AutoProxy.app")
    }

    func testRejectsForeignBundle() throws {
        let zip = try packApp(bundleID: "com.someone.else", version: "0.4.0")
        XCTAssertThrowsError(try Installer.unpack(zip: zip, expecting: Version("0.4.0")!))
    }

    func testRejectsVersionThatDisagreesWithTheTag() throws {
        // tag 说 0.4.0、包里是 0.3.0，装上去等于原地踏步，而且下次检查还会再下一遍
        let zip = try packApp(bundleID: AppInfo.bundleID, version: "0.3.0")
        XCTAssertThrowsError(try Installer.unpack(zip: zip, expecting: Version("0.4.0")!))
    }

    /// 造一个能被 open 起来又立刻退出的最小 .app
    private func stubApp(named name: String, marker: String) throws -> URL {
        let app = sandbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let plist: [String: Any] = ["CFBundleIdentifier": "me.ikvarxt.autoproxy.swapstub",
                                    "CFBundleExecutable": "stub"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let stub = app.appendingPathComponent("Contents/MacOS/stub")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return app
    }

    func testSwapReplacesTheBundleAndClearsTheBackup() throws {
        let dest = try stubApp(named: "Installed.app", marker: "old")
        let new = try stubApp(named: "New.app", marker: "new")

        // macOS 的 PID 上限是 99998，99999 保证不存在 —— 脚本不用等，直接进搬运
        try Installer.scheduleSwap(newApp: new, over: dest, waitFor: 99999)

        let marker = dest.appendingPathComponent("marker")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? String(contentsOf: marker, encoding: .utf8)) != "new" {
            usleep(100_000)
        }

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "新包应该被搬走而不是留下副本")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".old"), "备份该在搬完后清掉")
    }

    func testSwapKeepsTheOldCopyWhenTheNewOneIsMissing() throws {
        let dest = sandbox.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "old".write(to: dest.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        // 脚本等的是本进程退出，这里等不到 —— 直接跑一遍它的搬运部分，验证回滚
        let backup = dest.path + ".old"
        let missing = sandbox.appendingPathComponent("nope.app").path
        let script = """
        mv "$DEST" "$BACKUP" || exit 1
        mv "$NEW" "$DEST" || { mv "$BACKUP" "$DEST"; exit 1; }
        """
        let result = Shell.run("/bin/sh", ["-c",
            "DEST='\(dest.path)' BACKUP='\(backup)' NEW='\(missing)' sh -c '\(script)'"], timeout: 30)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("marker").path))
    }
}

/// 拦下 Updater 发出的请求，按 URL 喂回预置的响应。
private final class StubProtocol: URLProtocol {
    /// URLProtocol 由系统实例化，塞不进依赖，只能走静态的。测试是串行的，够用。
    static var feed: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let feed = StubProtocol.feed else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: feed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ManualCheckTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "autoproxy.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        StubProtocol.feed = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        StubProtocol.feed = nil
        super.tearDown()
    }

    private func updater(current: String) -> Updater {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return Updater(store: Store(defaults: defaults),
                       current: Version(current)!,
                       session: URLSession(configuration: config))
    }

    private func release(_ tag: String) -> Data {
        """
        {"tag_name":"\(tag)","draft":false,"prerelease":false,
         "assets":[{"name":"AutoProxy-\(tag).zip","browser_download_url":"https://example.invalid/a.zip"}]}
        """.data(using: .utf8)!
    }

    private func outcome(of updater: Updater) -> CheckOutcome? {
        var result: CheckOutcome?
        let done = expectation(description: "checked")
        updater.check {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    func testSaysUpToDateWhenTheLatestReleaseIsWhatWeAreRunning() {
        StubProtocol.feed = release("v0.4.0")
        guard case .upToDate = outcome(of: updater(current: "0.4.0")) else {
            return XCTFail("应当报告已是最新")
        }
    }

    func testReportsFailureRatherThanUpToDateWhenGitHubIsUnreachable() {
        // 问不到和「已是最新」得分开说 —— 混在一起，网络挂了的人会以为自己手上就是最新版
        guard case .failed = outcome(of: updater(current: "0.4.0")) else {
            return XCTFail("网络失败不能报成已是最新")
        }
    }

    func testGarbageResponseIsAFailureToo() {
        StubProtocol.feed = Data("not json".utf8)
        guard case .failed = outcome(of: updater(current: "0.4.0")) else {
            return XCTFail("解析不了也算没问到")
        }
    }

    func testAnnouncesTheDownloadBeforeItFinishes() {
        StubProtocol.feed = release("v0.9.0")
        guard case .downloading(let version) = outcome(of: updater(current: "0.4.0")) else {
            return XCTFail("发现新版本时应当先回一句正在下载")
        }
        XCTAssertEqual("\(version)", "0.9.0")
    }

    func testRecordsTheCheckEvenWhenNothingIsNew() {
        StubProtocol.feed = release("v0.4.0")
        _ = outcome(of: updater(current: "0.4.0"))
        XCTAssertNotNil(Store(defaults: defaults).lastUpdateCheck)
    }
}
