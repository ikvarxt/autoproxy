import XCTest
@testable import AutoProxy

final class StoreTests: XCTestCase {
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

    func testPortDefaultsTo9000WhenNeverSet() {
        XCTAssertEqual(Store(defaults: defaults).port, 9000)
    }

    func testPortSurvivesANewStore() {
        Store(defaults: defaults).port = 8888
        // 下次启动是一个全新的 Store 读同一份 defaults
        XCTAssertEqual(Store(defaults: defaults).port, 8888)
    }

    func testPortFallsBackWhenStoredValueIsUnusable() {
        defaults.set(0, forKey: "proxyPort")
        XCTAssertEqual(Store(defaults: defaults).port, 9000, "0 是 UserDefaults 读不到时的返回值，不能当端口用")
    }

    func testStaleRecordRemembersThePortThatWasActuallyUsed() {
        let store = Store(defaults: defaults)
        let phone = Device(serial: "S1", model: "SM_S9110", state: "device")
        store.port = 8888
        store.remember(device: phone, proxyOn: true, port: 8888)

        let stale = store.stale()
        XCTAssertEqual(stale?.port, 8888, "离场提示要给出手机上真正残留的端口，不是当前配置")
        XCTAssertEqual(stale?.model, "SM S9110")
    }

    func testClearedDeviceLeavesNoStaleRecord() {
        let store = Store(defaults: defaults)
        let phone = Device(serial: "S1", model: "SM_S9110", state: "device")
        store.remember(device: phone, proxyOn: true, port: 9000)
        store.remember(device: phone, proxyOn: false, port: 9000)

        XCTAssertNil(store.stale())
    }
}
