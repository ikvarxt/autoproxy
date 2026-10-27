import Foundation

/// 开代理的时候顺手把手机画面摆到 Mac 上。抓包要一边点手机一边看请求，
/// 低头点和在屏幕上点是两种效率。
///
/// 只管自己起的那一个会话：用户自己开着的 scrcpy 不碰、不杀 ——
/// 跟「只清指向本机端口的代理」是同一条原则。
final class Mirror {
    /// 找它要跑一遍登录 shell（用户的 PATH 在那儿），所以查一次存着。nil 表示没装。
    private(set) var executable: String?
    private var session: Process?

    /// 没装 scrcpy 时开关要置灰 —— 开了也没用，不如一眼看出来缺什么。
    var available: Bool { executable != nil }

    /// 起不来时说一声。窗口没出来又没有任何解释，人只会以为开关坏了。
    var onFailure: ((String) -> Void)?

    init(executable: String? = nil) {
        self.executable = executable
    }

    static let candidates = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]

    /// scrcpy 自己会去找 adb，找到的可能不是我们正在用的那个。版本一对不上，
    /// 它会 kill 掉现有 server 重起一个 —— 所有 reverse 隧道跟着没，正在抓的包当场断。
    /// 所以把 adb 的位置直接交给它。
    static func environment(adb: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let adb { env["ADB"] = adb }
        return env
    }

    /// 多台手机插着的时候漏掉 -s，投出来的是另一台 —— 不报错，只是看着不对。
    static func arguments(serial: String) -> [String] {
        ["-S", "-s", serial]
    }

    /// 跑登录 shell 十几秒起步，不能占着主线程。查完回主线程给结果。
    func locate(then done: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Shell.locate("scrcpy", extraCandidates: Mirror.candidates)
            DispatchQueue.main.async {
                self?.executable = found
                done()
            }
        }
    }

    /// 已经有一个在跑就不再开：重复的窗口没有意义，而且第二个会抢不到设备直接退出。
    func start(serial: String, adb: String?) {
        guard let executable, session?.isRunning != true else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Mirror.arguments(serial: serial)
        process.environment = Mirror.environment(adb: adb)
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                // 我们主动收掉的那次，引用早在 stop() 里摘了，这里就对不上 —— 不当成出错
                guard let self, self.session === finished else { return }
                self.session = nil
                guard finished.terminationStatus != 0 else { return }
                self.onFailure?("scrcpy 退出了（代码 \(finished.terminationStatus)）。"
                    + "在终端里手敲一遍 scrcpy -s \(serial) 能看到它到底在抱怨什么。")
            }
        }

        do {
            try process.run()
            session = process
        } catch {
            onFailure?("scrcpy 没能启动：\(error.localizedDescription)")
        }
    }

    /// -S 把手机屏幕关掉了，scrcpy 退出时才会恢复。所以停代理、关程序都得把它收掉 ——
    /// 留一台黑着屏的手机在桌上，正是这个工具本来要消灭的那种状态。
    func stop() {
        guard let session else { return }
        // 先摘引用再发信号：terminationHandler 据此分辨是我们收的还是它自己死的
        self.session = nil
        session.terminate()
    }
}
