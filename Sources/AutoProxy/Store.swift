import Foundation

/// 拔线后 adb 连接即断，Mac 再也读不到手机状态。离场期间唯一的依据就是这份记录。
/// 它只用于推断，设备一旦重新接入立即以实测为准。
struct Store {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var port: Int {
        get {
            let stored = defaults.integer(forKey: Key.port)
            return stored > 0 ? stored : 9000
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.port)
            defaults.synchronize()
        }
    }

    func remember(device: Device, proxyOn: Bool, port: Int) {
        defaults.set(proxyOn, forKey: Key.proxyOn(device.serial))
        defaults.set(device.model, forKey: Key.model(device.serial))
        defaults.set(port, forKey: Key.portFor(device.serial))

        var seen = defaults.stringArray(forKey: Key.seen) ?? []
        if !seen.contains(device.serial) {
            seen.append(device.serial)
            defaults.set(seen, forKey: Key.seen)
        }
    }

    func stale() -> StaleRecord? {
        for serial in defaults.stringArray(forKey: Key.seen) ?? [] where defaults.bool(forKey: Key.proxyOn(serial)) {
            let model = defaults.string(forKey: Key.model(serial)) ?? serial
            let port = defaults.integer(forKey: Key.portFor(serial))
            return StaleRecord(model: model.replacingOccurrences(of: "_", with: " "), port: port > 0 ? port : 9000)
        }
        return nil
    }

    private enum Key {
        static let port = "proxyPort"
        static let seen = "seenSerials"
        static func proxyOn(_ serial: String) -> String { "proxyOn.\(serial)" }
        static func model(_ serial: String) -> String { "model.\(serial)" }
        static func portFor(_ serial: String) -> String { "port.\(serial)" }
    }
}
