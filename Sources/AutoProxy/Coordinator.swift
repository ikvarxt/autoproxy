import Foundation

enum CertificateError: LocalizedError {
    case pushFailed(String)

    var errorDescription: String? {
        switch self {
        case .pushFailed(let detail): return detail
        }
    }
}

struct ProbeResult {
    let state: CaptureState
    let recovery: RecoveryAction
    /// 当场所有非 offline 的设备，菜单据此给出选择项
    var present: [Device] = []
    /// 不是活跃设备，却还挂着我们这个端口的代理 —— 该清掉
    var strays: [Device] = []
}

/// 所有对设备的读写都经过这里。它不认识 AppKit，便于单测。
final class Coordinator {
    let adb: Adb?
    let store: Store

    init(adb: Adb? = Adb.locate(), store: Store = Store()) {
        self.adb = adb
        self.store = store
    }

    func probe() -> ProbeResult {
        guard let adb else { return ProbeResult(state: .adbMissing, recovery: .none) }

        let port = store.port
        var snapshot = Snapshot(port: port, stale: store.stale())

        let present = adb.devices().filter { $0.state != "offline" }
        guard let device = Coordinator.pick(from: present, active: store.activeSerial) else {
            return ProbeResult(state: CaptureState.derive(from: snapshot), recovery: .none)
        }
        if store.activeSerial != device.serial { store.activeSerial = device.serial }
        snapshot.device = device

        if device.isUsable {
            // 必须赶在下面的 remember 之前读 —— 那句会把记录刷成本次实测值，
            // 而「上次离开时开着没有」正是判断要不要自动接回去的唯一依据。
            snapshot.wasCapturing = store.wasCapturing(serial: device.serial)
            snapshot.proxy = adb.proxy(device.serial)
            snapshot.hasTunnel = adb.hasReverse(device.serial, port: port)
            snapshot.portListening = ProxyProbe.isListening(port: port)

            switch snapshot.proxy {
            case .set: store.remember(device: device, proxyOn: true, port: port)
            case .unset: store.remember(device: device, proxyOn: false, port: port)
            case .unreadable: break  // 读不到不等于没有，宁可保留上一次的记录
            }
        }

        return ProbeResult(state: CaptureState.derive(from: snapshot),
                           recovery: CaptureState.recovery(from: snapshot),
                           present: present,
                           strays: strays(besides: device, among: present, port: port))
    }

    /// 记住的那台优先。它不在场（或还没选过）就退回当场第一台，由调用方把记录改过去。
    static func pick(from devices: [Device], active: String?) -> Device? {
        if let active, let match = devices.first(where: { $0.serial == active }) { return match }
        return devices.first
    }

    /// 只认指向本机这个端口的代理。指向别处的是别人设的，不替他做主 —— 与自动重连同一条原则。
    private func strays(besides active: Device, among devices: [Device], port: Int) -> [Device] {
        guard devices.count > 1, let adb else { return [] }
        return devices.filter { $0.serial != active.serial && $0.isUsable }
            .filter { adb.proxy($0.serial) == .set("127.0.0.1:\(port)") }
    }

    /// 切到另一台。代理状态跟着人走 —— 切换的意图就是「换台手机接着来」。
    /// 返回非 nil 表示新设备没接上，由调用方告诉用户；旧的那台交给 stray 清理。
    func switchTo(_ target: Device, carryProxy: Bool) -> String? {
        store.activeSerial = target.serial
        guard carryProxy else { return nil }

        guard target.isUsable else { return "\(target.label) 还没授权 USB 调试。" }
        guard ProxyProbe.isListening(port: store.port) else {
            // 端口空着还设代理，手机的流量会全发向一个不存在的端口，比不切糟得多
            return "本机 \(store.port) 端口没人监听，先打开代理软件。"
        }
        start(target)
        return nil
    }

    /// 同一时刻只让一台手机挂着我们的代理。切走之后那台仍指着本机端口，而菜单里已经
    /// 看不到它了 —— 不清掉，它被拔走就是一台上不了网、还没人知道为什么的手机。
    func evict(_ devices: [Device]) {
        for device in devices { stop(device) }
    }

    /// 执行 `CaptureState.recovery` 给出的动作。做什么由那个纯函数决定，这里只负责落地。
    func recover(_ action: RecoveryAction, device: Device) {
        guard let adb else { return }
        switch action {
        case .none:
            break
        case .restoreLink:
            start(device)
        case .repairTunnel:
            adb.addReverse(device.serial, port: store.port)
        }
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

    /// 换端口。正在代理就把链路整条迁过去 —— 只改配置会把手机留在指向旧端口的断网状态。
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
