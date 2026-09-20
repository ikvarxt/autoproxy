import XCTest
@testable import AutoProxy

final class AdbParsingTests: XCTestCase {
    func testParseDevicesReadsSerialStateAndModel() {
        let output = """
        List of devices attached
        R3CT10FAKE1           device product:e3qxxx model:SM_S9110 device:e3q transport_id:5
        emulator-5554         offline
        """
        let devices = Adb.parseDevices(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "R3CT10FAKE1")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[0].label, "SM S9110")
        XCTAssertTrue(devices[0].isUsable)
        XCTAssertEqual(devices[1].state, "offline")
        XCTAssertFalse(devices[1].isUsable)
    }

    func testParseDevicesAcceptsTabSeparatedOutput() {
        let devices = Adb.parseDevices("List of devices attached\nR3CT10FAKE1\tdevice\n")

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].isUsable)
        XCTAssertEqual(devices[0].label, "R3CT10FAKE1", "没有 model 字段时用序列号顶上")
    }

    func testParseDevicesKeepsUnauthorizedDevice() {
        let devices = Adb.parseDevices("List of devices attached\nR3CT10FAKE1\tunauthorized\n")

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].isUnauthorized)
        XCTAssertFalse(devices[0].isUsable)
    }

    func testParseDevicesIgnoresDaemonChatter() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached

        """
        XCTAssertTrue(Adb.parseDevices(output).isEmpty, "daemon 提示行有三段，不能被当成设备")
    }

    func testParseTrackedDevicesFingerprintIncludesState() {
        let before = Adb.parseTrackedDevices("R3CT10FAKE1\tunauthorized\n")
        let after = Adb.parseTrackedDevices("R3CT10FAKE1\tdevice\n")

        XCTAssertNotEqual(before, after, "授权状态变化必须触发重新探测")
        XCTAssertEqual(Adb.parseTrackedDevices(""), [])
    }

    func testParseProxyDistinguishesSetFromUnset() {
        XCTAssertEqual(Adb.parseProxy("127.0.0.1:9000"), .set("127.0.0.1:9000"))
        XCTAssertEqual(Adb.parseProxy("null"), .unset)
        XCTAssertEqual(Adb.parseProxy(":0"), .unset)
        XCTAssertEqual(Adb.parseProxy(""), .unset)
    }

    func testReverseListContainsMatchesOnlyTheRequestedPort() {
        let list = "UsbFfs tcp:9000 tcp:9000\nUsbFfs tcp:8080 tcp:8080\n"
        XCTAssertTrue(Adb.reverseListContains(list, port: 9000))
        XCTAssertTrue(Adb.reverseListContains(list, port: 8080))
        XCTAssertFalse(Adb.reverseListContains(list, port: 900))
        XCTAssertFalse(Adb.reverseListContains("", port: 9000))
    }
}
