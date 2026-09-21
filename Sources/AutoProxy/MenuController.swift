import AppKit
import UniformTypeIdentifiers

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = Coordinator()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let probeQueue = DispatchQueue(label: "me.ikvarxt.autoproxy.probe")

    private var monitor: DeviceMonitor?
    private var timer: Timer?
    private var state: CaptureState = .noDevice
    private var renderedKey = ""
    private var menuIsOpen = false
    private var probing = false
    private var lastRecovery: (serial: String, at: Date)?
    private var present: [Device] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()

        if let adb = coordinator.adb {
            monitor = DeviceMonitor(adb: adb) { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            monitor?.start()
        }

        // 事件驱动管插拔，这条定时器只负责刷新链路细节（代理端退出、隧道被移除）
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        // 这条不能挪到后台：异步派发出去，进程已经走完退出流程，手机上的代理就留着了
        if case .capturing(let device) = state { coordinator.stop(device) }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        render()
    }

    // MARK: - Probing

    private func refresh() {
        guard !probing else { return }
        probing = true
        probeQueue.async { [weak self] in
            guard let self else { return }
            let result = self.coordinator.probe()
            DispatchQueue.main.async {
                self.probing = false
                self.state = result.state
                self.present = result.present
                self.evictStrays(result.strays)
                self.autoRecover(result)
                guard !self.menuIsOpen, self.renderKey != self.renderedKey else { return }
                self.render()
            }
        }
    }

    /// 同一台设备 20 秒内只自动动手一次。补隧道这种动作在链路真修不好时会被定时器
    /// 反复触发，节流让它退化成低频重试，而不是每 3 秒对手机发一轮命令。
    private func autoRecover(_ result: ProbeResult) {
        guard coordinator.store.autoReconnect,
              result.recovery != .none,
              let device = result.state.device,
              !recentlyRecovered(device.serial)
        else { return }

        lastRecovery = (device.serial, Date())
        probeQueue.async { [weak self] in
            guard let self else { return }
            self.coordinator.recover(result.recovery, device: device)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// 切换活跃设备后，旧的那台还挂着我们的代理。它已经从菜单的操作范围里出去了，
    /// 留着不管，等于给人埋一台拔走就上不了网的手机。
    private func evictStrays(_ strays: [Device]) {
        guard !strays.isEmpty else { return }
        probeQueue.async { [weak self] in
            guard let self else { return }
            self.coordinator.evict(strays)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    private func recentlyRecovered(_ serial: String) -> Bool {
        guard let last = lastRecovery, last.serial == serial else { return false }
        return Date().timeIntervalSince(last.at) < 20
    }

    // MARK: - Actions

    @objc private func toggleCapture() {
        switch state {
        case .ready(let device, _):
            guard confirmStart(device) else { return }
            perform { self.coordinator.start(device) }
        case .capturing(let device), .brokenLink(let device, _):
            perform { self.coordinator.stop(device) }
        default: return
        }
    }

    /// 凡是会跑 adb 的动作都走这里。正常 10ms 无所谓，但设备半死不活时 Shell 会等满
    /// 超时上限，那段时间里主线程要是在等，整个菜单栏（不止本 app）都会僵住。
    private func perform(_ work: @escaping () -> Void) {
        probeQueue.async { [weak self] in
            work()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String,
              serial != coordinator.store.activeSerial,
              let target = present.first(where: { $0.serial == serial })
        else { return }

        var carryProxy = false
        if case .capturing = state { carryProxy = true }
        lastRecovery = nil
        renderedKey = ""

        probeQueue.async { [weak self] in
            guard let self else { return }
            let problem = self.coordinator.switchTo(target, carryProxy: carryProxy)
            DispatchQueue.main.async {
                if let problem { self.warn("代理没能跟着切过来", problem) }
                self.refresh()
            }
        }
    }

    /// 开代理这件事的后果全在手机那边，而且拔线不会自动消失。首次开启前必须说清楚，
    /// 勾了「不再提示」就不再拦 —— 知道一次就够了，每次都弹只是噪音。
    private func confirmStart(_ device: Device) -> Bool {
        guard !coordinator.store.startWarningAcknowledged else { return true }

        let alert = NSAlert()
        alert.messageText = "用完先点「停止代理」，再拔线"
        alert.informativeText =
            "代理设置留在 \(device.label) 上，拔线不会消失，手机上也没有入口能改 —— 直接拔走就是全程上不了网。"

        let acknowledged = NSButton(checkboxWithTitle: "我知道了，不用再提示", target: nil, action: nil)
        acknowledged.sizeToFit()
        alert.accessoryView = acknowledged
        alert.addButton(withTitle: "开启代理")
        alert.addButton(withTitle: "取消")

        guard runModal(alert) == .alertFirstButtonReturn else { return false }
        if acknowledged.state == .on { coordinator.store.startWarningAcknowledged = true }
        return true
    }

    @objc private func showStrandedHelp() {
        guard case .offlineStranded(let model, let port) = state else { return }
        let alert = NSAlert()
        alert.messageText = "\(model) 现在可能上不了网"
        alert.informativeText = """
        上次离开时，它的系统代理仍指向 127.0.0.1:\(port)。

        USB 线一拔，隧道就消失了，手机所有 HTTP 流量会发向一个不存在的端口 —— 表现为信号满格、Wi-Fi 正常，但什么网页都打不开。

        重启手机没有用。这个设置重启不丢，而且手机的设置界面里没有任何入口可以改它。

        两条路：

        1. 把手机插回这台 Mac，本工具会自动检测并一键清理。
        2. 人不在电脑边时，在手机上用 Termux 执行：
             settings put global http_proxy :0
        """
        alert.addButton(withTitle: "知道了")
        runModal(alert)
    }

    @objc private func installCertificate() {
        guard let device = state.device else { return }

        let panel = NSOpenPanel()
        panel.message = "选择代理软件的根证书"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["crt", "cer", "pem", "der"].compactMap { UTType(filenameExtension: $0) }
        if let directory = ProxyProbe.reqableCertificateDirectory {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        probeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let name = try self.coordinator.installCertificate(localPath: url.path, on: device)
                DispatchQueue.main.async { self.certificatePushed(name: name, on: device) }
            } catch {
                DispatchQueue.main.async { self.warn("推送证书失败", error.localizedDescription) }
            }
        }
    }

    private func certificatePushed(name: String, on device: Device) {
        let alert = NSAlert()
        alert.messageText = "证书已推送到 \(device.label)"
        alert.informativeText = """
        手机上已打开「从设备存储空间安装」。接下来要你在手机上点三下：

        1. CA 证书
        2. 在文件列表里选 \(name)
        3. 确定（可能要求输入锁屏密码）

        这三步省不掉。由 adb 发起的 CA 安装会被系统直接拒绝（「必须在设置中安装来自 Shell 的此证书」），只有用户在设置里亲自确认才作数。
        """
        alert.addButton(withTitle: "好")
        runModal(alert)
    }

    @objc private func editPort() {
        let alert = NSAlert()
        alert.messageText = "本机代理端口"
        alert.informativeText = "填写 Reqable / Charles / mitmproxy 等代理软件监听的端口。"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(coordinator.store.port)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let detected = ProxyProbe.detectReqablePort()
        if let detected { alert.addButton(withTitle: "用 Reqable 的 \(detected)") }

        switch runModal(alert) {
        case .alertFirstButtonReturn:
            if let port = Int(field.stringValue), (1..<65536).contains(port) { apply(port: port) }
        case .alertThirdButtonReturn:
            if let detected { apply(port: detected) }
        default:
            break
        }
    }

    private func apply(port: Int) {
        guard port != coordinator.store.port else { return }
        var capturing = false
        if case .capturing = state { capturing = true }
        let device = state.device
        renderedKey = ""
        perform { self.coordinator.changePort(to: port, device: device, wasCapturing: capturing) }
    }

    @objc private func toggleAutoReconnect() {
        coordinator.store.autoReconnect = !coordinator.store.autoReconnect
        lastRecovery = nil
        renderedKey = ""
        refresh()
        render()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func warn(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        runModal(alert)
    }

    @discardableResult
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: - Rendering

    /// 状态行之外，设备列表和选中项的变化也要让菜单重画
    private var renderKey: String {
        state.headline + "|" + present.map(\.serial).joined(separator: ",")
            + "|" + (coordinator.store.activeSerial ?? "")
    }

    private func render() {
        renderedKey = renderKey
        statusItem.button?.image = StatusIcon.image(for: state.icon)
        statusItem.button?.toolTip = state.headline

        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let headline = NSMenuItem(title: state.headline, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)

        if present.count > 1 {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "只管一台，其余自动清理", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            for device in present {
                let item = NSMenuItem(title: device.label, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.serial
                item.state = device.serial == coordinator.store.activeSerial ? .on : .off
                menu.addItem(item)
            }
        }

        if case .offlineStranded = state {
            add(to: menu, title: "查看问题与解决方案…", action: #selector(showStrandedHelp))
        }
        menu.addItem(.separator())

        switch state {
        case .ready:
            add(to: menu, title: "开启代理", action: #selector(toggleCapture))
        case .capturing:
            add(to: menu, title: "停止代理", action: #selector(toggleCapture))
        case .brokenLink:
            add(to: menu, title: "清理手机代理", action: #selector(toggleCapture))
        case .unauthorized:
            let hint = NSMenuItem(title: "去手机上点「允许 USB 调试」", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        case .adbMissing:
            let hint = NSMenuItem(title: "PATH 里找不到 adb", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        case .noDevice, .offlineStranded:
            break
        }

        if state.device != nil {
            add(to: menu, title: "安装代理证书…", action: #selector(installCertificate))
        }
        add(to: menu, title: "代理端口：\(coordinator.store.port)…", action: #selector(editPort))

        let auto = NSMenuItem(title: "重新插上时自动接回", action: #selector(toggleAutoReconnect), keyEquivalent: "")
        auto.target = self
        auto.state = coordinator.store.autoReconnect ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        add(to: menu, title: "退出", action: #selector(quit), key: "q")
    }

    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}
