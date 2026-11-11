import Foundation

/// 手表 ↔ 手机之间传输用的键。
enum Wire {
    static let sessionID = "sessionID"
    static let index = "index"
    static let start = "start"
    static let duration = "duration"
    static let deleteSession = "deleteSession"
    static let capturePaused = "capturePaused"
}
