import Foundation

enum CertificateError: LocalizedError {
    case pushFailed(String)

    var errorDescription: String? {
        switch self {
        case .pushFailed(let detail): return detail
        }
    }
}

/// 所有对设备的读写都经过这里。它不认识 AppKit，便于单测。
final class Coordinator {
    let adb: Adb?
    let store: Store

    init(adb: Adb? = Adb.locate(), store: Store = Store()) {
        self.adb = adb
        self.store = store
    }

    func probe() -> CaptureState {
        guard let adb else { return .adbMissing }

        let port = store.port
        var snapshot = Snapshot(port: port, stale: store.stale())

        guard let device = adb.devices().first(where: { $0.state != "offline" }) else {
            return CaptureState.derive(from: snapshot)
        }
        snapshot.device = device

        if device.isUsable {
            snapshot.proxy = adb.proxy(device.serial)
            snapshot.hasTunnel = adb.hasReverse(device.serial, port: port)
            snapshot.portListening = ProxyProbe.isListening(port: port)

            switch snapshot.proxy {
            case .set: store.remember(device: device, proxyOn: true, port: port)
            case .unset: store.remember(device: device, proxyOn: false, port: port)
            case .unreadable: break  // 读不到不等于没有，宁可保留上一次的记录
            }
        }

        return CaptureState.derive(from: snapshot)
    }

    func start(_ device: Device) {
        guard let adb else { return }
        let port = store.port
        // 顺序是硬约束：隧道必须先于代理建立，反过来会有一个窗口期手机流量发向不存在的端口。
        adb.addReverse(device.serial, port: port)
        adb.setProxy(device.serial, value: "127.0.0.1:\(port)")
        store.remember(device: device, proxyOn: true, port: port)
    }

    /// port 留空即当前配置的端口；改端口时要传旧端口，否则旧隧道拆不掉。
    func stop(_ device: Device, port: Int? = nil) {
        guard let adb else { return }
        let port = port ?? store.port
        // 同理，代理必须先于隧道撤销。
        adb.clearProxy(device.serial)
        adb.removeReverse(device.serial, port: port)
        store.remember(device: device, proxyOn: false, port: port)
    }

    /// 换端口。正在抓包就把链路整条迁过去 —— 只改配置会把手机留在指向旧端口的断网状态。
    func changePort(to port: Int, device: Device?, wasCapturing: Bool) {
        if let device { stop(device, port: store.port) }
        store.port = port
        if let device, wasCapturing { start(device) }
    }

    /// 推证书并拉起系统的安装页。装不装由用户在设置里点 —— adb 发起的 CA 安装会被系统拒绝。
    @discardableResult
    func installCertificate(localPath: String, on device: Device) throws -> String {
        guard let adb else { throw CertificateError.pushFailed("找不到 adb") }

        let name = URL(fileURLWithPath: localPath).lastPathComponent
        let push = adb.push(device.serial, localPath: localPath, remotePath: "/sdcard/Download/\(name)")
        guard push.ok else { throw CertificateError.pushFailed(push.trimmed) }

        adb.openCertificateInstaller(device.serial)
        return name
    }
}
