import Foundation

/// 只回答「这个端口上有没有代理在听」，不问是谁在听。
/// Reqable / Charles / mitmproxy / Proxyman 因此一视同仁。
enum ProxyProbe {
    static func isListening(port: Int) -> Bool {
        Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).out.contains("LISTEN")
    }

    /// 端口自动识别是便利功能，读不到就让用户自己填。
    static func detectReqablePort() -> Int? {
        let config = NSHomeDirectory() + "/Library/Application Support/com.reqable.macosx/config/capture_config"
        guard let data = FileManager.default.contents(atPath: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["proxyPort"] as? Int, port > 0
        else { return nil }
        return port
    }

    static var reqableCertificateDirectory: String? {
        let dir = NSHomeDirectory() + "/Library/Application Support/com.reqable.macosx/certificate"
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }
}
