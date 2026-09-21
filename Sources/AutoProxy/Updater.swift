import Foundation

/// 语义化版本。按字符串比会把 0.10.0 排在 0.9.0 前面，所以逐段比数字。
struct Version: Comparable, CustomStringConvertible {
    private let parts: [Int]

    init?(_ text: String) {
        let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !fields.isEmpty, !fields.contains(nil) else { return nil }
        parts = fields.compactMap { $0 }
    }

    private func segment(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) where lhs.segment(i) != rhs.segment(i) {
            return lhs.segment(i) < rhs.segment(i)
        }
        return false
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        (0..<max(lhs.parts.count, rhs.parts.count)).allSatisfy { lhs.segment($0) == rhs.segment($0) }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct Release {
    let version: Version
    let zip: URL
}

enum UpdateError: LocalizedError {
    case unpackFailed(String)
    /// 包里的东西跟 release 说的对不上 —— 下一步要拿它覆盖正在运行的程序，不能将就
    case mismatch
    case swapFailed(String)

    var errorDescription: String? {
        switch self {
        case .unpackFailed(let detail): return "解压失败：\(detail)"
        case .mismatch: return "下载到的包不是本程序的对应版本，已丢弃。"
        case .swapFailed(let detail): return "替换失败：\(detail)"
        }
    }
}

enum AppInfo {
    static let bundleID = "me.ikvarxt.autoproxy"
    static let latestRelease = URL(string: "https://api.github.com/repos/ikvarxt/autoproxy/releases/latest")!

    static var runningVersion: Version {
        Version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? Version("0")!
    }
}

enum ReleaseFeed {
    /// 从 GitHub releases/latest 的响应里取版本号和 .zip 资产。
    static func parse(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["draft"] as? Bool != true,
              root["prerelease"] as? Bool != true,
              let tag = root["tag_name"] as? String,
              let version = Version(tag),
              let assets = root["assets"] as? [[String: Any]]
        else { return nil }

        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let link = zip?["browser_download_url"] as? String, let url = URL(string: link) else { return nil }
        return Release(version: version, zip: url)
    }
}

/// 每天问一次 GitHub 有没有新版本，有就下回来放着。**什么时候装由调用方决定** ——
/// 装一次要重启进程，而退出时会清掉手机上的代理，正抓着包的时候干这事等于掐断链路。
final class Updater {
    /// 下载解压完、等着换上去的那个版本。
    /// 它和 busy 都只在主线程读写 —— 菜单那边也要读 staged，两头都待在主线程就不用上锁。
    private(set) var staged: (version: Version, app: URL)?

    private let store: Store
    private let current: Version
    private let session: URLSession
    private var timer: Timer?
    private var onStaged: (() -> Void)?
    private var busy = false

    init(store: Store, current: Version = AppInfo.runningVersion, session: URLSession = .shared) {
        self.store = store
        self.current = current
        self.session = session
    }

    /// 定时器每小时醒一次，真正发请求的门槛是「距上次检查满 24 小时」。
    /// 不用 24 小时的定时器：Mac 合盖的时间不算数，那样几天也轮不到一次检查。
    func start(onStaged: @escaping () -> Void) {
        self.onStaged = onStaged
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        checkIfDue()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfDue() {
        guard store.autoUpdate, staged == nil, !busy else { return }
        if let last = store.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check()
    }

    /// 手动查一次，跳过 24 小时的门槛。只在主线程调。
    func check() {
        guard !busy else { return }
        busy = true

        var request = URLRequest(url: AppInfo.latestRelease)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            let release = data.flatMap(ReleaseFeed.parse)

            DispatchQueue.main.async {
                self.store.lastUpdateCheck = Date()
                guard let release, release.version > self.current else {
                    self.busy = false
                    return
                }
                self.download(release)
            }
        }.resume()
    }

    private func download(_ release: Release) {
        session.downloadTask(with: release.zip) { [weak self] location, _, _ in
            guard let self else { return }
            // 回调跑在 URLSession 自己的线程上，解压就地做；结果回主线程再落到 staged
            let app = location.flatMap { Updater.stage($0, release) }

            DispatchQueue.main.async {
                self.busy = false
                guard let app else { return }
                self.staged = (release.version, app)
                self.onStaged?()
            }
        }.resume()
    }

    /// 落地、解压、校验。downloadTask 给的临时文件在回调返回后就被删掉，得先搬走。
    private static func stage(_ downloaded: URL, _ release: Release) -> URL? {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoproxy-update-\(release.version)")
        try? FileManager.default.removeItem(at: work)

        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.moveItem(at: downloaded, to: work.appendingPathComponent("app.zip"))) != nil
        else { return nil }

        guard let app = try? Installer.unpack(zip: work.appendingPathComponent("app.zip"),
                                              expecting: release.version) else {
            try? FileManager.default.removeItem(at: work)
            return nil
        }
        return app
    }
}

enum Installer {
    /// 解压并当场核对包里装的是什么。下一步要拿它覆盖正在运行的程序，
    /// 校验失败宁可什么都不做 —— bundle id 或版本对不上，说明下到的根本不是这次要的东西。
    static func unpack(zip: URL, expecting version: Version) throws -> URL {
        let dir = zip.deletingLastPathComponent().appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let result = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 120)
        guard result.ok else { throw UpdateError.unpackFailed(result.trimmed) }

        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed("包里没有 .app")
        }

        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == AppInfo.bundleID,
              let shipped = Version(plist["CFBundleShortVersionString"] as? String ?? ""),
              shipped == version
        else { throw UpdateError.mismatch }

        return app
    }

    /// 排一段脚本，等本进程退出后把新版本换上去再拉起来。
    ///
    /// 自我替换有个硬约束：进程活着的时候动不了自己的 bundle，所以搬运只能交给外部进程。
    /// 三步搬运（旧的挪走 → 新的就位 → 删旧的）里任何一步失败都还能退回旧版本；
    /// 写成「先删后拷」的话，拷贝一失败机器上就没有这个 app 了。
    static func scheduleSwap(newApp: URL, over bundle: URL,
                             waitFor pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        // 等待有上限：PID 可能被系统复用，无限等下去这次更新就永远搬不成。
        // 超时硬搬也是安全的 —— macOS 允许移动正在运行的 bundle，旧进程继续用已打开的 inode。
        let script = """
        #!/bin/sh
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 300 ]; do
          sleep 0.2
          i=$((i + 1))
        done
        rm -rf "$BACKUP"
        mv "$DEST" "$BACKUP" || exit 1
        mv "$NEW" "$DEST" || { mv "$BACKUP" "$DEST"; exit 1; }
        rm -rf "$BACKUP"
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("autoproxy-swap.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        // 路径经环境变量传进去，不拼进脚本文本 —— 装在哪儿是用户定的，带空格或引号都不能让脚本跑歪
        process.environment = [
            "PID": String(pid),
            "NEW": newApp.path,
            "DEST": bundle.path,
            "BACKUP": bundle.path + ".old",
        ]

        do {
            try process.run()
        } catch {
            throw UpdateError.swapFailed("\(error)")
        }
    }
}
