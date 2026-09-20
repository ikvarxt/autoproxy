import Foundation

struct CommandResult {
    let code: Int32
    let out: String

    var ok: Bool { code == 0 }
    var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(code: -1, out: "\(error)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(code: process.terminationStatus, out: String(data: data, encoding: .utf8) ?? "")
    }

    static func locate(_ executable: String, extraCandidates: [String] = []) -> String? {
        for candidate in extraCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // 登录 shell 才会加载用户的 PATH（mise / homebrew 都靠它），非交互 shell 找不到
        let result = run("/bin/zsh", ["-lc", "which \(executable)"])
        let path = result.trimmed
        return result.ok && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
