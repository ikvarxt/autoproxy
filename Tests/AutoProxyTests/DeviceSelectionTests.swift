import XCTest
@testable import AutoProxy

final class DeviceSelectionTests: XCTestCase {
    private let a = Device(serial: "A1", model: "SM_S9110", state: "device")
    private let b = Device(serial: "B2", model: "Pixel_8", state: "device")

    func testPicksTheRememberedDevice() {
        XCTAssertEqual(Coordinator.pick(from: [a, b], active: "B2"), b)
    }

    func testPicksFirstWhenNothingRemembered() {
        XCTAssertEqual(Coordinator.pick(from: [a, b], active: nil), a)
    }

    func testFallsBackWhenTheRememberedDeviceIsGone() {
        // 记住的那台拔走了，不能因此变成无设备可用
        XCTAssertEqual(Coordinator.pick(from: [b], active: "A1"), b)
    }

    func testNoDevicesYieldsNil() {
        XCTAssertNil(Coordinator.pick(from: [], active: "A1"))
    }
}

final class ActiveDeviceStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "autoproxy.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testActiveSerialIsNilBeforeAnythingIsChosen() {
        XCTAssertNil(Store(defaults: defaults).activeSerial)
    }

    func testActiveSerialSurvivesANewStore() {
        Store(defaults: defaults).activeSerial = "B2"
        XCTAssertEqual(Store(defaults: defaults).activeSerial, "B2")
    }

    func testStartWarningShowsUntilAcknowledged() {
        let store = Store(defaults: defaults)
        XCTAssertFalse(store.startWarningAcknowledged, "没勾过就得提示")
        store.startWarningAcknowledged = true
        XCTAssertTrue(Store(defaults: defaults).startWarningAcknowledged, "勾过一次就不该再提示")
    }
}
