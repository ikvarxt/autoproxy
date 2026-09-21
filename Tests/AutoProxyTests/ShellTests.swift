import XCTest
@testable import AutoProxy

final class ShellTests: XCTestCase {
    func testNormalCommandStillReturnsOutputAndCode() {
        let result = Shell.run("/bin/echo", ["hi"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.trimmed, "hi")
    }

    func testFailingCommandKeepsItsExitCode() {
        let result = Shell.run("/bin/sh", ["-c", "exit 3"])
        XCTAssertEqual(result.code, 3)
    }

    func testHangingCommandGivesUpAtTheTimeout() {
        let started = Date()
        let result = Shell.run("/bin/sleep", ["30"], timeout: 0.5)

        XCTAssertFalse(result.ok, "超时必须走失败分支，否则调用方会把空输出当成真实状态")
        XCTAssertTrue(result.out.contains("超时"), result.out)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "等待必须有上限")
    }

    func testTimeoutKillsTheProcess() throws {
        let marker = "autoproxy-timeout-\(UUID().uuidString)"
        Shell.run("/bin/sh", ["-c", "sleep 30 # \(marker)"], timeout: 0.5)

        // 超时只是不再等它，没杀掉的话进程会一直挂着，下一条命令又开一个
        let survivors = Shell.run("/bin/ps", ["-Ao", "command"]).out
        XCTAssertFalse(survivors.contains(marker))
    }

    func testTimeoutIsGenerousEnoughForASlowButNormalCommand() {
        let result = Shell.run("/bin/sh", ["-c", "sleep 1; echo done"], timeout: 10)
        XCTAssertEqual(result.trimmed, "done")
    }
}
