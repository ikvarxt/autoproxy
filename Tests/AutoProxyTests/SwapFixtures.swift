import Foundation
@testable import AutoProxy

/// 搬运脚本只看目录本身，一个带 marker 的空目录就够分辨新旧。
func stubApp(in sandbox: URL, named name: String, marker: String) throws -> URL {
    let app = sandbox.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try marker.write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    return app
}

/// 等脚本整个跑完再断言：它先把新包挪到位、再删备份，盯着 marker 变就去查备份会抢在删除前面。
func swap(newApp: URL, over dest: URL, removing source: URL? = nil) throws {
    // macOS 的 PID 上限是 99998，99999 保证不存在 —— 脚本不用等，直接进搬运
    let script = try Installer.scheduleSwap(newApp: newApp, over: dest, removing: source,
                                            waitFor: 99999, relaunch: false)
    script.waitUntilExit()
}
