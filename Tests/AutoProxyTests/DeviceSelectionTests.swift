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

final class SwitchTests: XCTestCase {
    private var suite: String!
    private var store: Store!
    private var coordinator: Coordinator!

    override func setUp() {
        super.setUp()
        suite = "autoproxy.tests.\(UUID().uuidString)"
        store = Store(defaults: UserDefaults(suiteName: suite)!)
        coordinator = Coordinator(adb: nil, store: store)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSwitchingWithoutAnOpenProxyJustMovesTheSelection() {
        let target = Device(serial: "B2", model: "Pixel_8", state: "device")
        XCTAssertNil(coordinator.switchTo(target, carryProxy: false))
        XCTAssertEqual(store.activeSerial, "B2")
    }

    func testUnauthorizedTargetIsReported() {
        let target = Device(serial: "B2", model: "Pixel_8", state: "unauthorized")
        let problem = coordinator.switchTo(target, carryProxy: true)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("Pixel 8") == true, "提示里要说清是哪台")
    }

    func testProxyDoesNotFollowWhenNobodyIsListening() {
        store.port = 54_321  // 没人监听的端口：设过去等于把手机流量导进黑洞
        let target = Device(serial: "B2", model: "Pixel_8", state: "device")
        XCTAssertNotNil(coordinator.switchTo(target, carryProxy: true))
    }

    func testSelectionMovesEvenWhenTheProxyCannotFollow() {
        store.port = 54_321
        let target = Device(serial: "B2", model: "Pixel_8", state: "device")
        _ = coordinator.switchTo(target, carryProxy: true)
        XCTAssertEqual(store.activeSerial, "B2", "代理没跟过来，但人确实是要切的")
    }
}
