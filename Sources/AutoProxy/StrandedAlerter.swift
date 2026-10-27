import Foundation

/// 决定什么时候提醒「手机被落下了」。
///
/// 只看这一轮刚从列表里消失的那几台：落盘记录里可能还躺着很久以前别的手机的
/// 「代理开着」，拿它来提醒就是报错了手机，甚至这次拔的那台根本没开代理。
/// 拔走是一次性的边沿，天然只响一次；插回来再拔是新的一次。
struct StrandedAlerter {
    private var present: Set<String> = []

    /// 返回非 nil 表示这一次该提醒，内容是刚拔走那台留下的记录。
    mutating func departed(_ devices: [Device], record: (String) -> StaleRecord?) -> StaleRecord? {
        let now = Set(devices.map(\.serial))
        defer { present = now }
        return present.subtracting(now).sorted().lazy.compactMap(record).first
    }
}
