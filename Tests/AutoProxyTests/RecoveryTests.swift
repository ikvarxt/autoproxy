import XCTest
@testable import AutoProxy

final class RecoveryTests: XCTestCase {
    private let phone = Device(serial: "R3CT10FAKE1", model: "SM_S9110", state: "device")

    private func snapshot(
        device: Device? = nil,
        proxy: ProxySetting = .unset,
        hasTunnel: Bool = false,
        portListening: Bool = true,
        wasCapturing: Bool = false
    ) -> Snapshot {
        var s = Snapshot(port: 9000, stale: nil)
        s.device = device
        s.proxy = proxy
        s.hasTunnel = hasTunnel
        s.portListening = portListening
        s.wasCapturing = wasCapturing
        return s
    }

    func testDeviceBackWithProxyGoneIsRestored() {
        let s = snapshot(device: phone, proxy: .unset, wasCapturing: true)
        XCTAssertEqual(CaptureState.recovery(from: s), .restoreLink)
    }

    /// 端口没人监听时重连会把手机推进「信号满格但打不开任何网页」的状态，
    /// 比什么都不做糟得多 —— 这条是整个自动重连里最要紧的一道闸。
    func testNothingHappensWhenTheProxyAppIsNotListening() {
        let s = snapshot(device: phone, proxy: .unset, portListening: false, wasCapturing: true)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testDeviceThatWasNotCapturingIsLeftAlone() {
        let s = snapshot(device: phone, proxy: .unset, wasCapturing: false)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testProxyStillSetButTunnelGoneRepairsTheTunnel() {
        let s = snapshot(device: phone, proxy: .set("127.0.0.1:9000"), hasTunnel: false)
        XCTAssertEqual(CaptureState.recovery(from: s), .repairTunnel)
    }

    func testHealthyLinkNeedsNothing() {
        let s = snapshot(device: phone, proxy: .set("127.0.0.1:9000"), hasTunnel: true)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testProxyPointingSomewhereElseIsSomeoneElsesBusiness() {
        let s = snapshot(device: phone, proxy: .set("10.0.0.2:8888"), hasTunnel: false)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testUnauthorizedDeviceIsNotTouched() {
        let pending = Device(serial: "R3CT10FAKE1", model: "", state: "unauthorized")
        let s = snapshot(device: pending, proxy: .unset, wasCapturing: true)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testUnreadableProxyIsNotGuessedAt() {
        let s = snapshot(device: phone, proxy: .unreadable, wasCapturing: true)
        XCTAssertEqual(CaptureState.recovery(from: s), .none)
    }

    func testAbsentDeviceHasNothingToRecover() {
        XCTAssertEqual(CaptureState.recovery(from: snapshot(wasCapturing: true)), .none)
    }

    /// 自动重连后的实测应当落在 capturing 上，否则图标会跟链路对不上
    func testRestoredLinkDerivesToCapturing() {
        let after = snapshot(device: phone, proxy: .set("127.0.0.1:9000"), hasTunnel: true)
        XCTAssertEqual(CaptureState.derive(from: after), .capturing(phone))
        XCTAssertEqual(CaptureState.recovery(from: after), .none)
    }
}
