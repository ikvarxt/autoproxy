import Foundation

/// 决定什么时候提醒「手机被落下了」。
///
/// 这个状态会一直挂着直到手机插回来，而探测每 3 秒一轮 —— 每轮都提醒就是骚扰。
/// 所以只在刚变成这个状态时响一次，换了台手机或换了端口算新情况，再响一次。
struct StrandedAlerter {
    private var announced: StaleRecord?

    /// 返回非 nil 表示这一次该提醒，内容就是它。
    mutating func announce(_ state: CaptureState) -> StaleRecord? {
        guard case .offlineStranded(let model, let port) = state else {
            announced = nil
            return nil
        }
        let record = StaleRecord(model: model, port: port)
        guard record != announced else { return nil }
        announced = record
        return record
    }
}
