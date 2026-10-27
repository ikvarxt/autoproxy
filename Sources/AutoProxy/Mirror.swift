import Foundation

/// 手机连着的时候把画面摆到 Mac 上。要一边点手机一边看请求，
/// 低头点和在屏幕上点是两种效率 —— 跟抓不抓包没关系，插着就该在。
///
/// 只管自己起的那一个会话：用户自己开着的 scrcpy 不碰、不杀 ——
/// 跟「只清指向本机端口的代理」是同一条原则。
final class Mirror {
    /// 找它要跑一遍登录 shell（用户的 PATH 在那儿），所以查一次存着。nil 表示没装。
    private(set) var executable: String?
    private var session: Process?
    private var mirroring: String?
    private var startedAt: Date?
    private var refusing: String?

    /// 没装 scrcpy 时开关要置灰 —— 开了也没用，不如一眼看出来缺什么。
    var available: Bool { executable != nil }

    init(executable: String? = nil) {
        self.executable = executable
    }

    /// 此刻该投哪台、还是该收摊。单独拎出来是因为条件有四个（开关、装没装、
    /// 设备在不在、授权没授权），散在调用点上容易漏掉其中一个。
    static func intent(enabled: Bool, available: Bool, device: Device?) -> Intent {
        guard enabled, available, let device, device.isUsable else { return .off }
        return .mirror(device.serial)
    }

    enum Intent: Equatable {
        case mirror(String)
        case off
    }

    static let candidates = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]

    /// 我们起的 scrcpy 窗口叫这个。用户自己开的不会有 —— 那种不碰、不杀。
    ///
    /// 标记打在窗口标题而不是环境变量上：孤儿的父进程已经是 launchd，
    /// `ps -E` 读不到它的环境（试过，拿回来的是空的），命令行参数则谁都能看。
    /// 顺带让人一眼看出这个窗口是谁开的。
    static let windowTitle = "AutoProxy"

    /// scrcpy 自己会去找 adb，找到的可能不是我们正在用的那个。版本一对不上，
    /// 它会 kill 掉现有 server 重起一个 —— 所有 reverse 隧道跟着没，正在抓的包当场断。
    /// 所以把 adb 的位置直接交给它。
    static func environment(adb: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let adb { env["ADB"] = adb }
        return env
    }

    /// 从 ps 输出里挑出上一条命留下的 scrcpy。
    ///
    /// 拆成纯函数是因为这里误判的代价不对称：漏掉只是多一个窗口，
    /// 多杀一个就是把用户自己开着的投屏掐了。所以三个条件都要硬碰硬 ——
    /// 可执行文件真的是 scrcpy（scrcpy 自己起的 adb 子进程命令行里也有 "scrcpy"）、
    /// 窗口标题是我们打的、而且不是本进程正开着的那个。
    static func strays(in listing: String, mine: Int32) -> [Int32] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  Int32(fields[1]) != mine,
                  fields[2].hasSuffix("/scrcpy"),
                  line.contains("--window-title=\(windowTitle)-") else { return nil }
            return pid
        }
    }

    /// 收掉前任留下的孤儿。被 SIGKILL、崩溃、部署脚本的 pkill 都会留下它：
    /// 新进程拿不到那个 Process 对象就管不了它，再起一个就是两个窗口抢同一台设备。
    static func clearStrays() {
        let listed = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5)
        guard listed.ok else { return }
        for pid in strays(in: listed.out, mine: ProcessInfo.processInfo.processIdentifier) {
            kill(pid, SIGTERM)
        }
    }

    /// 多台手机插着的时候漏掉 -s，投出来的是另一台 —— 不报错，只是看着不对。
    static func arguments(serial: String) -> [String] {
        ["-S", "-s", serial, "--window-title=\(windowTitle)-\(serial)"]
    }

    /// 跑登录 shell 十几秒起步，不能占着主线程。查完回主线程给结果。
    func locate(then done: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 先清前任，不然待会儿对齐设备时又起一个，就是两个
            Mirror.clearStrays()
            let found = Shell.locate("scrcpy", extraCandidates: Mirror.candidates)
            DispatchQueue.main.async {
                self?.executable = found
                done()
            }
        }
    }

    /// 已经在投同一台就什么都不做：重复的窗口没有意义，而且第二个抢不到设备会直接退出。
    /// 投的是另一台（切了活跃设备）就先把旧的收掉。
    func start(serial: String, adb: String?) {
        guard let executable, refusing != serial else { return }
        if session?.isRunning == true {
            guard mirroring != serial else { return }
            stop()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Mirror.arguments(serial: serial)
        process.environment = Mirror.environment(adb: adb)
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                // 我们主动收掉的那次，引用早在 stop() 里摘了，这里就对不上 —— 不当成出错
                guard let self, self.session === finished else { return }
                let lived = Date().timeIntervalSince(self.startedAt ?? Date())
                self.session = nil
                self.mirroring = nil
                self.startedAt = nil
                // 断了就断了，不打扰：拔线、关窗口都会走到这儿，调试时本来就常拔。
                // 只记一笔「起来就死」的设备（参数不对、被别的 scrcpy 占着之类）——
                // 不记的话每轮探测都会再拉一次，变成后台闷头刷进程。
                guard finished.terminationStatus != 0, lived < 5 else { return }
                self.refusing = serial
            }
        }

        do {
            try process.run()
            session = process
            mirroring = serial
            startedAt = Date()
        } catch {
            refusing = serial
        }
    }

    /// -S 把手机屏幕关掉了，scrcpy 退出时才会恢复。所以关掉开关、关程序都得把它收掉 ——
    /// 留一台黑着屏的手机在桌上，正是这个工具本来要消灭的那种状态。
    func stop() {
        // 拔线和关开关都经过这里，正好是重置「起来就死」记录的时机：
        // 下次插上再试一次，不然一次失手就得重启程序才肯再投。
        refusing = nil
        guard let session else { return }
        // 先摘引用再发信号：terminationHandler 据此分辨是我们收的还是它自己死的
        self.session = nil
        mirroring = nil
        startedAt = nil
        session.terminate()
    }
}
