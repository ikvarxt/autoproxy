import XCTest
@testable import AutoProxy

final class MirrorCommandTests: XCTestCase {
    func testAlwaysNamesTheDevice() {
        // 插着两台时漏掉 -s，投出来的是另一台 —— 不报错，只是看着不对
        XCTAssertEqual(Mirror.arguments(serial: "RFCW718JZCA"), ["-S", "-s", "RFCW718JZCA"])
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
        var complaints: [String] = []
        mirror.onFailure = { complaints.append($0) }
        mirror.start(serial: "X", adb: nil)
        XCTAssertEqual(complaints, [])
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

    func testStoppingIsNotReportedAsAFailure() {
        // 收掉自己起的会话会让它以非 0 退出。把这当故障报，每次停代理都要弹一次窗
        let mirror = Mirror(executable: script.path)
        let quiet = expectation(description: "没有抱怨")
        quiet.isInverted = true
        mirror.onFailure = { _ in quiet.fulfill() }

        mirror.start(serial: "X", adb: nil)
        mirror.stop()
        wait(for: [quiet], timeout: 1.5)
    }

    func testSecondStartIsIgnoredWhileOneIsRunning() throws {
        let mirror = Mirror(executable: script.path)
        mirror.start(serial: "X", adb: nil)
        let first = try XCTUnwrap(Mirror_session(of: mirror))
        mirror.start(serial: "X", adb: nil)
        XCTAssertTrue(Mirror_session(of: mirror) === first, "已经有一个在跑就不该再开")
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
