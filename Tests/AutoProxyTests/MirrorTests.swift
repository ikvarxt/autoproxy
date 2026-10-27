import XCTest
@testable import AutoProxy

final class MirrorCommandTests: XCTestCase {
    func testAlwaysNamesTheDevice() {
        // 插着两台时漏掉 -s，投出来的是另一台 —— 不报错，只是看着不对
        XCTAssertEqual(Mirror.arguments(serial: "RFCW718JZCA").prefix(3), ["-S", "-s", "RFCW718JZCA"])
    }

    func testHandsScrcpyTheSameAdbWeUse() {
        // 版本对不上的两个 adb 会互相 kill server，隧道跟着全没
        XCTAssertEqual(Mirror.environment(adb: "/opt/homebrew/bin/adb")["ADB"], "/opt/homebrew/bin/adb")
    }

    func testWithoutAdbItFallsBackToScrcpysOwnLookup() {
        XCTAssertNil(Mirror.environment(adb: nil)["ADB"])
    }

    func testUnavailableWithoutScrcpy() {
        XCTAssertFalse(Mirror(executable: nil).available)
    }

    func testStartingWithoutScrcpyIsSilentRatherThanFatal() {
        let mirror = Mirror(executable: nil)
        mirror.start(serial: "X", adb: nil)
        XCTAssertNil(Mirror_session(of: mirror))
    }
}

final class MirrorStrayTests: XCTestCase {
    /// ps -axo pid=,ppid=,command= 的真实形状。ppid 1 = 父进程死了，它活下来了。
    private let orphan = "85547 1 /opt/homebrew/bin/scrcpy -S -s RFCW718JZCA --window-title=AutoProxy-RFCW718JZCA"
    private let theirs = "41203 1 /opt/homebrew/bin/scrcpy -s RFCY61GMGWD"
    private let helper = "85560 85547 /opt/homebrew/share/android-commandlinetools/platform-tools/adb -s RFCW718JZCA "
        + "shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server"

    func testFindsTheOneWeLeftBehind() {
        XCTAssertEqual(Mirror.strays(in: orphan, mine: 99999), [85547])
    }

    func testLeavesTheUsersOwnSessionAlone() {
        // 没打我们的标题就不是我们起的。杀错了是在掐别人正看着的屏
        XCTAssertEqual(Mirror.strays(in: theirs, mine: 99999), [])
    }

    func testDoesNotMistakeScrcpysOwnAdbForAStray() {
        // 它的命令行里也有 "scrcpy"，只有可执行文件本身能分辨
        XCTAssertEqual(Mirror.strays(in: helper, mine: 99999), [])
    }

    func testNeverKillsTheSessionThisProcessIsRunning() {
        // 不然启动清场那一下会把自己刚投上的收掉
        let live = "86176 86022 /opt/homebrew/bin/scrcpy -S -s X --window-title=AutoProxy-X"
        XCTAssertEqual(Mirror.strays(in: live, mine: 86022), [])
    }

    func testPicksOnlyOursOutOfAFullListing() {
        let listing = [theirs, helper, orphan, "1 0 /sbin/launchd"].joined(separator: "\n")
        XCTAssertEqual(Mirror.strays(in: listing, mine: 99999), [85547])
    }

    func testMarksTheWindowSoTheNextProcessCanFindIt() {
        XCTAssertTrue(Mirror.arguments(serial: "RFCW718JZCA")
            .contains("--window-title=AutoProxy-RFCW718JZCA"))
    }
}

final class MirrorIntentTests: XCTestCase {
    private let connected = Device(serial: "RFCW718JZCA", model: "SM_G991B", state: "device")

    func testMirrorsWheneverAUsableDeviceIsAttached() {
        // 跟抓不抓包没关系 —— 插着就该投
        XCTAssertEqual(Mirror.intent(enabled: true, available: true, device: connected),
                       .mirror("RFCW718JZCA"))
    }

    func testNothingToMirrorWhenTheDeviceIsGone() {
        XCTAssertEqual(Mirror.intent(enabled: true, available: true, device: nil), .off)
    }

    func testUnauthorizedDeviceIsNotMirrorable() {
        // 没授权的设备 scrcpy 推不上 server，起来就死
        let pending = Device(serial: "X", model: "X", state: "unauthorized")
        XCTAssertEqual(Mirror.intent(enabled: true, available: true, device: pending), .off)
    }

    func testTurningTheSwitchOffTakesTheSessionDown() {
        // -S 关掉的屏幕要等 scrcpy 退出才恢复，关开关必须真的把它收掉
        XCTAssertEqual(Mirror.intent(enabled: false, available: true, device: connected), .off)
    }

    func testWithoutScrcpyThereIsNothingToStart() {
        XCTAssertEqual(Mirror.intent(enabled: true, available: false, device: connected), .off)
    }
}

final class MirrorSessionTests: XCTestCase {
    private var script: URL!

    /// 一个忽略参数、不自己退出的假 scrcpy。
    override func setUpWithError() throws {
        script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-scrcpy-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: script)
        super.tearDown()
    }

    func testStoppingDoesNotCountAgainstTheDevice() throws {
        // 收掉自己起的会话会让它以非 0 退出。当成「这台投不了」记下来，就再也投不上了
        let mirror = Mirror(executable: script.path)
        mirror.start(serial: "X", adb: nil)
        mirror.stop()
        settle()
        mirror.start(serial: "X", adb: nil)
        XCTAssertNotNil(Mirror_session(of: mirror))
        mirror.stop()
    }

    func testADeviceThatDiesOnStartIsNotRetriedEveryPoll() throws {
        // 探测是秒级的。起不来还一轮一轮拉，就成了后台闷头刷进程 —— 还不弹窗，没人看得见
        let mirror = Mirror(executable: try dyingScript().path)
        mirror.start(serial: "X", adb: nil)
        settle()
        mirror.start(serial: "X", adb: nil)
        XCTAssertNil(Mirror_session(of: mirror))
    }

    func testUnpluggingForgetsThatSoTheNextPlugInTriesAgain() throws {
        // 一次失手就得重启程序才肯再投,那还不如没有这个开关
        let mirror = Mirror(executable: try dyingScript().path)
        mirror.start(serial: "X", adb: nil)
        settle()
        mirror.stop()  // 拔线/关开关都走这儿
        mirror.start(serial: "X", adb: nil)
        XCTAssertNotNil(Mirror_session(of: mirror))
        settle()
    }

    /// 进程退出的善后挂在主线程上，得让 runloop 转一会儿它才轮得到。
    private func settle() {
        let turned = expectation(description: "主线程转过一轮")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { turned.fulfill() }
        wait(for: [turned], timeout: 2)
    }

    /// 一个起来就死的假 scrcpy。
    private func dyingScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dying-scrcpy-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSecondStartIsIgnoredWhileOneIsRunning() throws {
        let mirror = Mirror(executable: script.path)
        mirror.start(serial: "X", adb: nil)
        let first = try XCTUnwrap(Mirror_session(of: mirror))
        mirror.start(serial: "X", adb: nil)
        XCTAssertTrue(Mirror_session(of: mirror) === first, "已经有一个在跑就不该再开")
        mirror.stop()
    }

    func testSwitchingDevicesReplacesTheSession() throws {
        // 切了活跃设备还投着旧那台,画面和菜单说的就对不上了
        let mirror = Mirror(executable: script.path)
        mirror.start(serial: "A", adb: nil)
        let first = try XCTUnwrap(Mirror_session(of: mirror))
        mirror.start(serial: "B", adb: nil)
        let second = try XCTUnwrap(Mirror_session(of: mirror))
        XCTAssertFalse(second === first)
        mirror.stop()
    }

    func testStopIsSafeWhenNothingIsRunning() {
        let mirror = Mirror(executable: script.path)
        mirror.stop()
        mirror.stop()
    }
}

/// session 是私有的，测试只需要知道「还是不是同一个进程」。
private func Mirror_session(of mirror: Mirror) -> Process? {
    Swift.Mirror(reflecting: mirror).children
        .first { $0.label == "session" }?.value as? Process
}
