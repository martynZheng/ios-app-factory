import Foundation
import Speech

/// 转写队列：一次处理一个分段。默认只用端侧识别；
/// 只有用户在设置里明确允许后，才会在端侧不可用时使用 Apple 服务器识别。
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    @Published var busy = false
    @Published var authDenied = false

    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    static var localeID: String { UserDefaults.standard.string(forKey: "speechLocale") ?? "zh-CN" }
    static var allowServer: Bool { UserDefaults.standard.bool(forKey: "allowServerSpeech") }

    static func onDeviceSupported() -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    /// 设置变更后，把之前被挡住/失败的分段重新排队。
    func retryAll() {
        Store.shared.mutate { db in
            for i in db.segments.indices where (db.segments[i].status == .blocked || db.segments[i].status == .failed) && db.segments[i].hasAudio {
                db.segments[i].status = .pending
                db.segments[i].error = nil
            }
        }
        kick()
    }

    func kick() {
        guard !busy else { return }
        guard let seg = Store.shared.db.segments.sorted(by: { $0.start < $1.start }).first(where: { $0.status == .pending }) else { return }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.kick() } }
            return
        case .authorized:
            authDenied = false
        default:
            authDenied = true
            return
        }

        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)), rec.isAvailable else { return }
        let onDevice = rec.supportsOnDeviceRecognition
        if !onDevice && !Self.allowServer {
            Store.shared.updateSegment(seg.id) {
                $0.status = .blocked
                $0.error = "该语言在这台设备上不支持端侧识别。可在设置中允许使用 Apple 服务器转写。"
            }
            DispatchQueue.main.async { self.kick() }
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: Store.shared.audioURL(seg.id))
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        busy = true
        recognizer = rec
        var finished = false
        task = rec.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let lines = Self.makeLines(result.bestTranscription, segment: seg)
                    Store.shared.setLines(lines, for: seg.id)
                    Store.shared.updateSegment(seg.id) { $0.status = lines.isEmpty ? .noSpeech : .done; $0.error = nil }
                    self.finish()
                } else if let error {
                    finished = true
                    let ns = error as NSError
                    let noSpeech = ns.code == 1110 || ns.localizedDescription.lowercased().contains("no speech")
                    Store.shared.updateSegment(seg.id) {
                        $0.status = noSpeech ? .noSpeech : .failed
                        $0.error = noSpeech ? nil : ns.localizedDescription
                    }
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        task = nil
        recognizer = nil
        busy = false
        NotificationCenter.default.post(name: .transcriptChanged, object: nil)
        kick()
    }

    /// 把识别出的词按停顿和句末标点合并成句，每句带时间点。
    static func makeLines(_ transcription: SFTranscription, segment: Segment) -> [Line] {
        let joiner = (localeID.hasPrefix("zh") || localeID.hasPrefix("ja") || localeID.hasPrefix("yue")) ? "" : " "
        var lines: [Line] = []
        var current = ""
        var startOffset: Double = 0
        var lastEnd: Double = 0

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(Line(id: UUID(), segmentID: segment.id, time: segment.start.addingTimeInterval(startOffset),
                                  offset: startOffset, text: text, edited: false))
            }
            current = ""
        }

        for word in transcription.segments {
            let gap = word.timestamp - lastEnd
            if !current.isEmpty && (gap > 0.8 || current.count > 60) { flush() }
            if current.isEmpty { startOffset = word.timestamp }
            current += (current.isEmpty ? "" : joiner) + word.substring
            lastEnd = word.timestamp + word.duration
            if let last = word.substring.last, "。？！?!.".contains(last), current.count > 6 { flush() }
        }
        flush()
        if lines.isEmpty {
            let whole = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty {
                lines.append(Line(id: UUID(), segmentID: segment.id, time: segment.start, offset: 0, text: whole, edited: false))
            }
        }
        return lines
    }
}

extension Notification.Name {
    static let transcriptChanged = Notification.Name("transcriptChanged")
}
