import Foundation

/// 程序现在待的地方。这件事有实质后果：自我更新要把新版本搬到自己头上，
/// 而从 zip 里直接双击运行时，系统给的是一份隔离过的只读副本 —— 那儿谁也搬不动，
/// 自动更新会一路静默失败到用户以为它坏了。
enum InstallLocation: Equatable {
    /// 应用程序文件夹，该待的地方
    case installed
    /// 只读：挂载的磁盘映像，或系统为隔离的包生成的临时副本
    case readOnly
    /// 能跑也能自我更新，只是散落在下载目录之类的地方
    case loose

    var needsRelocation: Bool { self != .installed }

    /// 只看得见路径和「父目录写不写得进去」两件事，所以整段逻辑可以脱离真实文件系统来测。
    static func classify(
        bundle: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        writable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> InstallLocation {
        let parent = bundle.deletingLastPathComponent().resolvingSymlinksInPath()
        let accepted = [URL(fileURLWithPath: "/Applications"),
                        home.appendingPathComponent("Applications")]

        if accepted.contains(where: { $0.resolvingSymlinksInPath().path == parent.path }) { return .installed }
        return writable(parent) ? .loose : .readOnly
    }
}
