import Foundation

/// 手表 ↔ 手机之间传输用的键。
enum Wire {
    static let sessionID = "sessionID"
    static let index = "index"
    static let start = "start"
    static let duration = "duration"
    static let deleteSession = "deleteSession"
    static let capturePaused = "capturePaused"
    /// 手表的心跳：是否在录、为什么停了（lowBattery / stopped）、时间
    static let heartbeat = "heartbeat"
    static let recording = "recording"
    static let reason = "reason"
    static let at = "at"
}
