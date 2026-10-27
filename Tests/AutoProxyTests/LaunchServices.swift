import Foundation
@testable import AutoProxy

/// 测试在临时目录里造的 .app，LaunchServices 会自己扫进数据库。目录删了记录还留着 ——
/// 攒上几十条指向已经不存在的路径的死记录之后，系统按 bundle id 解析图标就可能命中其中一条，
/// 表现是通知横幅上没有图标。所以删目录之前先把它们摘掉。
///
/// 先 -f 再 -u：后台那次扫描什么时候轮到这个 bundle 不归我们管，光 -u 会扑空在
/// 「还没注册」的那个窗口里，等它扫完记录又回来了。先自己把它注册上，时序就是确定的。
func unregisterBundles(under directory: URL) {
    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"
    guard FileManager.default.isExecutableFile(atPath: lsregister),
          let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return }

    for case let url as URL in walker where url.pathExtension == "app" {
        _ = Shell.run(lsregister, ["-f", url.path], timeout: 10)
        _ = Shell.run(lsregister, ["-u", url.path], timeout: 10)
    }
}
