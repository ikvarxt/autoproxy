import Darwin
import Foundation

/// 监听 adb server 的 `host:track-devices` 长连接。
///
/// 相比轮询 `adb devices`，它能在插拔发生的那一刻拿到事件 —— 这正是记录「离场前代理是否开着」
/// 的唯一时机，晚一秒手机就已经拔走了。
final class DeviceMonitor {
    private let adb: Adb
    private let onChange: () -> Void

    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var stopping = false

    init(adb: Adb, onChange: @escaping () -> Void) {
        self.adb = adb
        self.onChange = onChange
    }

    func start() {
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "adb-track-devices"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopping = true
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - Loop

    private func loop() {
        var lastSnapshot: Set<String>?

        while !isStopping {
            guard let fd = openTrackingConnection() else {
                adb.startServer()
                Thread.sleep(forTimeInterval: 2)
                continue
            }

            lock.lock(); socketFD = fd; lock.unlock()

            while !isStopping, let payload = readMessage(fd) {
                let snapshot = Adb.parseTrackedDevices(payload)
                if snapshot != lastSnapshot {
                    lastSnapshot = snapshot
                    onChange()
                }
            }

            lock.lock()
            if socketFD == fd { close(fd); socketFD = -1 }
            lock.unlock()

            if !isStopping { Thread.sleep(forTimeInterval: 2) }
        }
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    // MARK: - adb wire protocol

    private func openTrackingConnection() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(5037).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected, send(fd, "host:track-devices"), readExactly(fd, 4).flatMap({ String(data: $0, encoding: .utf8) }) == "OKAY"
        else {
            close(fd)
            return nil
        }
        return fd
    }

    /// 每条消息是 4 位十六进制长度前缀加载荷；长度 0 表示设备列表为空，是合法消息而非断连。
    private func readMessage(_ fd: Int32) -> String? {
        guard let header = readExactly(fd, 4),
              let hex = String(data: header, encoding: .utf8),
              let length = Int(hex, radix: 16)
        else { return nil }
        if length == 0 { return "" }
        return readExactly(fd, length).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func send(_ fd: Int32, _ payload: String) -> Bool {
        let message = Array(String(format: "%04x", payload.utf8.count).utf8) + Array(payload.utf8)
        var sent = 0
        while sent < message.count {
            let written = message.withUnsafeBufferPointer { buffer in
                write(fd, buffer.baseAddress! + sent, message.count - sent)
            }
            if written <= 0 { return false }
            sent += written
        }
        return true
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let got = buffer.withUnsafeMutableBufferPointer { pointer in
                read(fd, pointer.baseAddress, count - data.count)
            }
            if got <= 0 { return nil }
            data.append(contentsOf: buffer[0..<got])
        }
        return data
    }
}
