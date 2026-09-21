import XCTest
@testable import AutoProxy

final class InstallLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    private func classify(_ path: String, writable: Bool = true) -> InstallLocation {
        InstallLocation.classify(bundle: URL(fileURLWithPath: path), home: home) { _ in writable }
    }

    func testApplicationsFoldersAreHome() {
        XCTAssertEqual(classify("/Applications/AutoProxy.app"), .installed)
        XCTAssertEqual(classify("/Users/tester/Applications/AutoProxy.app"), .installed)
    }

    func testNestedFolderInsideApplicationsStillNeedsMoving() {
        // /Applications/Utilities/… 不是 /Applications，别把它当已装好
        XCTAssertEqual(classify("/Applications/Utilities/AutoProxy.app"), .loose)
    }

    func testWritableElsewhereIsLoose() {
        XCTAssertEqual(classify("/Users/tester/Downloads/AutoProxy.app"), .loose)
    }

    func testUnwritableParentMeansReadOnly() {
        // 磁盘映像、以及系统给隔离包生成的那份临时副本，都落在这一档
        let translocated = "/private/var/folders/x/T/AppTranslocation/ABC/d/AutoProxy.app"
        XCTAssertEqual(classify(translocated, writable: false), .readOnly)
        XCTAssertEqual(classify("/Volumes/AutoProxy/AutoProxy.app", writable: false), .readOnly)
    }

    func testOnlyInstalledIsSettled() {
        XCTAssertFalse(InstallLocation.installed.needsRelocation)
        XCTAssertTrue(InstallLocation.loose.needsRelocation)
        XCTAssertTrue(InstallLocation.readOnly.needsRelocation)
    }
}

final class StrandedAlerterTests: XCTestCase {
    private let phone = Device(serial: "abc", model: "Pixel_7", state: "device")

    func testAnnouncesOnceWhileTheStateHolds() {
        var alerter = StrandedAlerter()
        let stranded = CaptureState.offlineStranded(model: "Pixel 7", port: 9000)

        XCTAssertEqual(alerter.announce(stranded), StaleRecord(model: "Pixel 7", port: 9000))
        // 这状态一直挂到手机插回来，而探测每 3 秒一轮 —— 每轮都响就是骚扰
        XCTAssertNil(alerter.announce(stranded))
        XCTAssertNil(alerter.announce(stranded))
    }

    func testAnnouncesAgainAfterTheDeviceComesBackAndLeavesOnceMore() {
        var alerter = StrandedAlerter()
        let stranded = CaptureState.offlineStranded(model: "Pixel 7", port: 9000)

        XCTAssertNotNil(alerter.announce(stranded))
        XCTAssertNil(alerter.announce(.capturing(phone)))
        XCTAssertNotNil(alerter.announce(stranded), "插回来又拔走是新的一次，该再提醒")
    }

    func testAnotherPhoneOrPortIsANewSituation() {
        var alerter = StrandedAlerter()
        XCTAssertNotNil(alerter.announce(.offlineStranded(model: "Pixel 7", port: 9000)))
        XCTAssertNotNil(alerter.announce(.offlineStranded(model: "Galaxy S23", port: 9000)))
        XCTAssertNotNil(alerter.announce(.offlineStranded(model: "Galaxy S23", port: 8888)))
    }

    func testStaysQuietForEveryOtherState() {
        var alerter = StrandedAlerter()
        for state in [CaptureState.noDevice, .adbMissing, .capturing(phone),
                      .ready(phone, portListening: true), .brokenLink(phone, reason: "x")] {
            XCTAssertNil(alerter.announce(state))
        }
    }
}

/// 搬运脚本在「目标还不存在」这条路径上的行为 —— 首次安装走的就是它。
final class RelocationTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoproxy-relocate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

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

    private func wait(for path: URL, toRead expected: String?) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let actual = try? String(contentsOf: path, encoding: .utf8)
            if actual == expected { return }
            usleep(100_000)
        }
    }

    func testInstallsWhenNothingIsThereYet() throws {
        let new = try stubApp(named: "New.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("Applications/AutoProxy.app")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // 首次安装时目标位置是空的。脚本要是无条件 mv 旧的去备份，这一步就直接失败了
        try Installer.scheduleSwap(newApp: new, over: dest, waitFor: 99999)

        let marker = dest.appendingPathComponent("marker")
        wait(for: marker, toRead: "fresh")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "fresh")
    }

    func testClearsTheCopyLeftBehindInDownloads() throws {
        let staged = try stubApp(named: "Staged.app", marker: "fresh")
        let source = try stubApp(named: "Downloads.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("AutoProxy.app")

        try Installer.scheduleSwap(newApp: staged, over: dest, removing: source, waitFor: 99999)

        wait(for: dest.appendingPathComponent("marker"), toRead: "fresh")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: source.path) { usleep(100_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "原地那份该清掉，留着只会让人下次双击到旧的")
    }

    func testNeverDeletesTheThingItJustInstalled() throws {
        let staged = try stubApp(named: "Staged.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("AutoProxy.app")

        // 源和目标同一个位置时，「清掉源」这一步会把刚装好的删掉
        try Installer.scheduleSwap(newApp: staged, over: dest, removing: dest, waitFor: 99999)

        wait(for: dest.appendingPathComponent("marker"), toRead: "fresh")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8), "fresh")
    }
}
