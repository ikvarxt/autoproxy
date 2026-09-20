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
            let next = self.coordinator.probe()
            DispatchQueue.main.async {
                self.probing = false
                self.state = next
                guard !self.menuIsOpen, next.headline != self.renderedKey else { return }
                self.render()
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleCapture() {
        switch state {
        case .ready(let device, _): coordinator.start(device)
        case .capturing(let device), .brokenLink(let device, _): coordinator.stop(device)
        default: return
        }
        refresh()
    }

    @objc private func showStrandedHelp() {
        guard case .offlineStranded(let model, let port) = state else { return }
        let alert = NSAlert()
        alert.messageText = "\(model) 现在可能上不了网"
        alert.informativeText = """
        上次抓包结束时，它的系统代理仍指向 127.0.0.1:\(port)。

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
        panel.message = "选择抓包软件的根证书"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["crt", "cer", "pem", "der"].compactMap { UTType(filenameExtension: $0) }
        if let directory = ProxyProbe.reqableCertificateDirectory {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let name = try coordinator.installCertificate(localPath: url.path, on: device)
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
        } catch {
            let alert = NSAlert()
            alert.messageText = "推送证书失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            runModal(alert)
        }
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
        coordinator.changePort(to: port, device: state.device, wasCapturing: capturing)
        renderedKey = ""
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @discardableResult
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: - Rendering

    private func render() {
        renderedKey = state.headline
        statusItem.button?.image = StatusIcon.image(for: state.icon)
        statusItem.button?.toolTip = state.headline

        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let headline = NSMenuItem(title: state.headline, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)

        if case .offlineStranded = state {
            add(to: menu, title: "查看问题与解决方案…", action: #selector(showStrandedHelp))
        }
        menu.addItem(.separator())

        switch state {
        case .ready:
            add(to: menu, title: "开启抓包", action: #selector(toggleCapture))
        case .capturing:
            add(to: menu, title: "停止抓包", action: #selector(toggleCapture))
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
            add(to: menu, title: "安装抓包证书…", action: #selector(installCertificate))
        }
        add(to: menu, title: "代理端口：\(coordinator.store.port)…", action: #selector(editPort))
        menu.addItem(.separator())
        add(to: menu, title: "退出", action: #selector(quit), key: "q")
    }

    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}
