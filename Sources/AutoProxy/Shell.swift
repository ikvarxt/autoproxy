import Foundation

struct CommandResult {
    let code: Int32
    let out: String

    var ok: Bool { code == 0 }
    var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// adb 正常在 10ms 内返回，但设备半死不活（offline、USB 接触不良）时它会一直等下去。
    /// 没有上限的等待会把调用方整条线程锁住，所以给每条命令一个硬上限。
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(code: -1, out: "\(error)")
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // 超时这条路径上不读管道：adb 可能已经把写端交给了后台 daemon，
            // 那样 readDataToEndOfFile 会一直等到 daemon 自己退出 —— 又是一次无上限等待。
            _ = exited.wait(timeout: .now() + 1)
            return CommandResult(code: -1, out: "命令超时（\(Int(timeout)) 秒）：\(path)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(code: process.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
    }

    static func locate(_ executable: String, extraCandidates: [String] = []) -> String? {
        for candidate in extraCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // 登录 shell 才会加载用户的 PATH（mise / homebrew 都靠它），非交互 shell 找不到。
        // 它要把用户整份 rc 跑一遍，比 adb 本身慢得多，超时放宽。
        let result = run("/bin/zsh", ["-lc", "which \(executable)"], timeout: 20)
        let path = result.trimmed
        return result.ok && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
