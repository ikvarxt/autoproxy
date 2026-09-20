import Foundation

struct StaleRecord: Equatable {
    let model: String
    let port: Int
}

/// 一次探测的全部输入。设备不在场时后四项无意义。
struct Snapshot: Equatable {
    var device: Device?
    var proxy: ProxySetting = .unreadable
    var hasTunnel: Bool = false
    var portListening: Bool = false
    var port: Int = 9000
    var stale: StaleRecord?
}

enum CaptureState: Equatable {
    case adbMissing
    case noDevice
    /// 设备已离场，而它离场前代理还开着 —— 那台手机现在多半上不了网
    case offlineStranded(model: String, port: Int)
    case unauthorized(Device)
    case ready(Device, portListening: Bool)
    case capturing(Device)
    case brokenLink(Device, reason: String)

    /// 设备在场时取到的设备，可操作的那些状态才有
    var device: Device? {
        switch self {
        case .ready(let d, _), .capturing(let d), .brokenLink(let d, _): return d
        case .unauthorized, .adbMissing, .noDevice, .offlineStranded: return nil
        }
    }

    var needsAttention: Bool {
        switch self {
        case .offlineStranded, .brokenLink: return true
        default: return false
        }
    }

    static func derive(from s: Snapshot) -> CaptureState {
        guard let device = s.device else {
            if let stale = s.stale { return .offlineStranded(model: stale.model, port: stale.port) }
            return .noDevice
        }
        guard device.isUsable else { return .unauthorized(device) }

        switch s.proxy {
        case .unreadable:
            return .unauthorized(device)
        case .unset:
            return .ready(device, portListening: s.portListening)
        case .set(let value):
            let expected = "127.0.0.1:\(s.port)"
            if value != expected {
                return .brokenLink(device, reason: "代理指向 \(value)，与端口 \(s.port) 不符")
            }
            if !s.hasTunnel { return .brokenLink(device, reason: "USB 隧道不存在") }
            if !s.portListening { return .brokenLink(device, reason: "端口 \(s.port) 无人监听") }
            return .capturing(device)
        }
    }
}

extension CaptureState {
    var headline: String {
        switch self {
        case .adbMissing: return "找不到 adb"
        case .noDevice: return "无设备"
        case .offlineStranded(let model, let port): return "\(model) 可能上不了网（代理 :\(port) 未清理）"
        case .unauthorized(let d): return "\(d.label) 未授权调试"
        case .ready(let d, let listening): return listening ? "就绪 · \(d.label)" : "就绪 · \(d.label)（端口无监听）"
        case .capturing(let d): return "抓包中 · \(d.label)"
        case .brokenLink(let d, let reason): return "\(d.label) 已断网 · \(reason)"
        }
    }
}

extension CaptureState {
    /// 形状和颜色双编码，不依赖辨色也能区分
    var glyph: String {
        switch self {
        case .capturing: return "●"
        case .ready(_, let listening): return listening ? "●" : "○"
        case .noDevice: return "○"
        case .offlineStranded, .brokenLink, .unauthorized, .adbMissing: return "▲"
        }
    }
}
