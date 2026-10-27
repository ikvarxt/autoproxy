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
    private let samsung = Device(serial: "RFCW718JZCA", model: "SM_S9110", state: "device")
    private let pixel = Device(serial: "abc", model: "Pixel_7", state: "device")
    private let left = StaleRecord(model: "SM S9110", port: 9000)

    func testAnnouncesTheMomentTheCapturingPhoneIsUnplugged() {
        var alerter = StrandedAlerter()
        XCTAssertNil(alerter.departed([samsung]) { _ in self.left })
        XCTAssertEqual(alerter.departed([]) { _ in self.left }, left)
    }

    func testAnnouncesOnceWhileItStaysUnplugged() {
        // 探测每 3 秒一轮，每轮都响就是骚扰
        var alerter = StrandedAlerter()
        _ = alerter.departed([samsung]) { _ in self.left }
        XCTAssertNotNil(alerter.departed([]) { _ in self.left })
        XCTAssertNil(alerter.departed([]) { _ in self.left })
    }

    func testAnnouncesAgainAfterItComesBackAndLeavesOnceMore() {
        var alerter = StrandedAlerter()
        _ = alerter.departed([samsung]) { _ in self.left }
        _ = alerter.departed([]) { _ in self.left }
        _ = alerter.departed([samsung]) { _ in self.left }
        XCTAssertNotNil(alerter.departed([]) { _ in self.left }, "插回来又拔走是新的一次")
    }

    func testIgnoresOldRecordsOfPhonesThatWereNotJustUnplugged() {
        // 拔的是三星、它没开代理，记录里却有台很久以前的手机标着「开着」—— 不能拿那台来报
        var alerter = StrandedAlerter()
        let records = ["8ADX0R5D0": StaleRecord(model: "TrebleDroid vanilla", port: 9000)]
        _ = alerter.departed([samsung]) { records[$0] }
        XCTAssertNil(alerter.departed([]) { records[$0] })
    }

    func testStaysQuietAtLaunchEvenIfARecordIsLeftOver() {
        // 启动时什么都没插不等于「刚拔了线」，那条记录留给菜单去说
        var alerter = StrandedAlerter()
        XCTAssertNil(alerter.departed([]) { _ in self.left })
    }

    func testUnpluggingOneOfTwoStillCounts() {
        var alerter = StrandedAlerter()
        _ = alerter.departed([samsung, pixel]) { _ in nil }
        XCTAssertEqual(alerter.departed([pixel]) { $0 == "RFCW718JZCA" ? self.left : nil }, left)
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

    func testInstallsWhenNothingIsThereYet() throws {
        let new = try stubApp(in: sandbox, named: "New.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("Applications/AutoProxy.app")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // 首次安装时目标位置是空的。脚本要是无条件 mv 旧的去备份，这一步就直接失败了
        try swap(newApp: new, over: dest)

        let marker = dest.appendingPathComponent("marker")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "fresh")
    }

    func testClearsTheCopyLeftBehindInDownloads() throws {
        let staged = try stubApp(in: sandbox, named: "Staged.app", marker: "fresh")
        let source = try stubApp(in: sandbox, named: "Downloads.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("AutoProxy.app")

        try swap(newApp: staged, over: dest, removing: source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "原地那份该清掉，留着只会让人下次双击到旧的")
    }

    func testNeverDeletesTheThingItJustInstalled() throws {
        let staged = try stubApp(in: sandbox, named: "Staged.app", marker: "fresh")
        let dest = sandbox.appendingPathComponent("AutoProxy.app")

        // 源和目标同一个位置时，「清掉源」这一步会把刚装好的删掉
        try swap(newApp: staged, over: dest, removing: dest)

        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8), "fresh")
    }
}
