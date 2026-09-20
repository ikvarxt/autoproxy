import Foundation

struct Device: Equatable {
    let serial: String
    let model: String
    let state: String

    var isUsable: Bool { state == "device" }
    var isUnauthorized: Bool { state == "unauthorized" }
    var label: String { model.replacingOccurrences(of: "_", with: " ") }
}

enum ProxySetting: Equatable {
    case unset
    case set(String)
    /// adb 命令本身失败了 —— 设备刚拔走、或授权被撤销，不代表手机上没有代理
    case unreadable
}

struct Adb {
    let path: String

    static func locate() -> Adb? {
        let candidates = [
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return Shell.locate("adb", extraCandidates: candidates).map(Adb.init(path:))
    }

    // MARK: - Queries

    func devices() -> [Device] {
        let result = Shell.run(path, ["devices", "-l"])
        return result.ok ? Adb.parseDevices(result.out) : []
    }

    func hasReverse(_ serial: String, port: Int) -> Bool {
        let result = Shell.run(path, ["-s", serial, "reverse", "--list"])
        return Adb.reverseListContains(result.out, port: port)
    }

    func proxy(_ serial: String) -> ProxySetting {
        let result = Shell.run(path, ["-s", serial, "shell", "settings", "get", "global", "http_proxy"])
        guard result.ok else { return .unreadable }
        return Adb.parseProxy(result.trimmed)
    }

    // MARK: - Mutations

    @discardableResult
    func addReverse(_ serial: String, port: Int) -> CommandResult {
        Shell.run(path, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
    }

    @discardableResult
    func removeAllReverses(_ serial: String) -> CommandResult {
        Shell.run(path, ["-s", serial, "reverse", "--remove-all"])
    }

    @discardableResult
    func setProxy(_ serial: String, value: String) -> CommandResult {
        Shell.run(path, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", value])
    }

    @discardableResult
    func clearProxy(_ serial: String) -> CommandResult {
        // 清空必须写 ":0"，写空串会留下一个畸形值，手机照样断网
        setProxy(serial, value: ":0")
    }

    @discardableResult
    func push(_ serial: String, localPath: String, remotePath: String) -> CommandResult {
        Shell.run(path, ["-s", serial, "push", localPath, remotePath])
    }

    @discardableResult
    func openCertificateInstaller(_ serial: String) -> CommandResult {
        // adb 把参数拼成一行交给设备 shell，$ 不转义会被展开成空，Activity 名就废了
        Shell.run(path, ["-s", serial, "shell", "am", "start", "-n",
                         "com.android.settings/.Settings\\$InstallCertificateFromStorageActivity"])
    }

    @discardableResult
    func startServer() -> CommandResult {
        Shell.run(path, ["start-server"])
    }

    // MARK: - Parsing

    /// 表头、`* daemon ...` 提示和设备行混在同一段输出里，靠状态词过滤比按行号跳更稳
    private static let deviceStates: Set<String> = [
        "device", "offline", "unauthorized", "authorizing", "connecting",
        "recovery", "sideload", "bootloader", "rescue",
    ]

    static func parseDevices(_ raw: String) -> [Device] {
        raw.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, deviceStates.contains(fields[1]) else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)) }
            return Device(serial: fields[0], model: model ?? fields[0], state: fields[1])
        }
    }

    /// `host:track-devices` 推的是 "serial\tstate" 行，没有 model。
    /// 指纹带上 state，是为了让 unauthorized → device 这类原地变化也能触发重新探测。
    static func parseTrackedDevices(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            return "\(fields[0])\t\(fields[1])"
        })
    }

    static func parseProxy(_ value: String) -> ProxySetting {
        (value.isEmpty || value == "null" || value == ":0") ? .unset : .set(value)
    }

    static func reverseListContains(_ raw: String, port: Int) -> Bool {
        raw.split(separator: "\n").contains { $0.hasSuffix("tcp:\(port) tcp:\(port)") }
    }
}
