import XCTest
@testable import AutoProxy

final class CaptureStateTests: XCTestCase {
    private let phone = Device(serial: "R3CT10FAKE1", model: "SM_S9110", state: "device")

    private func snapshot(
        device: Device? = nil,
        proxy: ProxySetting = .unset,
        hasTunnel: Bool = false,
        portListening: Bool = true,
        stale: StaleRecord? = nil
    ) -> Snapshot {
        var s = Snapshot(port: 9000, stale: stale)
        s.device = device
        s.proxy = proxy
        s.hasTunnel = hasTunnel
        s.portListening = portListening
        return s
    }

    func testTunnelAndProxyTogetherMeanCapturing() {
        let state = CaptureState.derive(from: snapshot(device: phone, proxy: .set("127.0.0.1:9000"), hasTunnel: true))
        guard case .capturing(let device) = state else { return XCTFail("期望 capturing，实际 \(state)") }
        XCTAssertEqual(device.serial, phone.serial)
    }

    func testProxyWithoutTunnelIsBrokenLink() {
        let state = CaptureState.derive(from: snapshot(device: phone, proxy: .set("127.0.0.1:9000"), hasTunnel: false))
        guard case .brokenLink = state else { return XCTFail("期望 brokenLink，实际 \(state)") }
    }

    func testProxyPointingElsewhereIsAlsoBrokenLink() {
        // 隧道在，但代理指向别的端口，手机流量照样发不出去
        let state = CaptureState.derive(from: snapshot(device: phone, proxy: .set("127.0.0.1:8888"), hasTunnel: true))
        guard case .brokenLink = state else { return XCTFail("期望 brokenLink，实际 \(state)") }
    }

    func testReadyCarriesWhetherTheProxyAppIsListening() {
        guard case .ready(_, let listening) = CaptureState.derive(from: snapshot(device: phone, portListening: true)) else {
            return XCTFail("期望 ready")
        }
        XCTAssertTrue(listening)

        guard case .ready(_, let idle) = CaptureState.derive(from: snapshot(device: phone, portListening: false)) else {
            return XCTFail("期望 ready")
        }
        XCTAssertFalse(idle)
    }

    func testUnauthorizedDeviceOutranksStaleRecord() {
        let unauthorized = Device(serial: "R3CT10FAKE1", model: "R3CT10FAKE1", state: "unauthorized")
        let stale = StaleRecord(model: "SM_S9110", port: 9000)
        let state = CaptureState.derive(from: snapshot(device: unauthorized, stale: stale))
        guard case .unauthorized = state else { return XCTFail("期望 unauthorized，实际 \(state)") }
    }

    func testStaleRecordWithoutDeviceIsOfflineStranded() {
        let stale = StaleRecord(model: "SM_S9110", port: 9000)
        let state = CaptureState.derive(from: snapshot(stale: stale))
        guard case .offlineStranded(let model, let port) = state else { return XCTFail("期望 offlineStranded") }
        XCTAssertEqual(model, "SM_S9110")
        XCTAssertEqual(port, 9000)
    }

    func testPresentDeviceHidesTheStaleRecordOfAnotherPhone() {
        // 实测优先：插着的这台是干净的，就报 ready，不拿另一台的历史记录吓人
        let stale = StaleRecord(model: "Pixel", port: 9000)
        let state = CaptureState.derive(from: snapshot(device: phone, stale: stale))
        guard case .ready = state else { return XCTFail("期望 ready，实际 \(state)") }
    }

    func testNoDeviceAndNoRecordIsIdle() {
        guard case .noDevice = CaptureState.derive(from: snapshot()) else { return XCTFail("期望 noDevice") }
    }

    func testEveryStateHasHeadlineAndGlyph() {
        let states: [CaptureState] = [
            .adbMissing, .noDevice, .offlineStranded(model: "SM_S9110", port: 9000),
            .unauthorized(phone), .ready(phone, portListening: false),
            .capturing(phone), .brokenLink(phone, reason: "隧道没了"),
        ]
        for state in states {
            XCTAssertFalse(state.headline.isEmpty, "\(state) 没有状态文案")
            XCTAssertFalse(state.glyph.isEmpty, "\(state) 没有图标")
        }
    }
}
