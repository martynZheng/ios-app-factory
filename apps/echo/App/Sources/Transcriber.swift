import AVFoundation
import CoreMedia
import Foundation
import Speech
import UIKit

/// 转写队列：一次处理一个分段，全部在本机完成。
/// - iOS 26+：用新的 SpeechAnalyzer / SpeechTranscriber（长音频、远场拾音明显更好）。
/// - 新引擎不可用或出错时：退回旧的 SFSpeechRecognizer 端侧识别。
/// - 只有用户明确允许时，才会在端侧完全不可用的情况下使用 Apple 服务器。
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    @Published var busy = false
    @Published var authDenied = false

    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var background: UIBackgroundTaskIdentifier = .invalid

    static var localeID: String { UserDefaults.standard.string(forKey: "speechLocale") ?? "zh-CN" }
    static var allowServer: Bool { UserDefaults.standard.bool(forKey: "allowServerSpeech") }

    /// 用户填的常用词（人名、项目名、术语），帮助识别。
    static var vocabulary: [String] {
        let raw = UserDefaults.standard.string(forKey: "vocab") ?? ""
        return raw.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func onDeviceSupported() -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    static var modernAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { [weak self] in self?.endBackground() }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
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

    /// 用当前引擎把某一天还留着音频的分段全部重新转写（旧文字和当天回顾会被替换）。
    func retranscribe(day: String) {
        let ids = Set(Store.shared.segments(on: day).filter { $0.hasAudio }.map { $0.id })
        guard !ids.isEmpty else { return }
        Store.shared.mutate { db in
            db.lines.removeAll { ids.contains($0.segmentID) }
            for i in db.segments.indices where ids.contains(db.segments[i].id) {
                db.segments[i].status = .pending
                db.segments[i].error = nil
            }
            db.digests[day] = nil
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

        busy = true
        beginBackground()
        if #available(iOS 26.0, *) {
            let url = Store.shared.audioURL(seg.id)
            let localeID = Self.localeID
            let vocab = Self.vocabulary
            Task {
                do {
                    let lines = try await ModernSpeech.transcribe(url: url, segment: seg, localeID: localeID, vocabulary: vocab)
                    await MainActor.run {
                        Store.shared.setLines(lines, for: seg.id)
                        Store.shared.updateSegment(seg.id) { $0.status = lines.isEmpty ? .noSpeech : .done; $0.error = nil }
                        self.finish()
                    }
                } catch {
                    let reason = error.localizedDescription
                    await MainActor.run { self.legacy(seg, note: "新引擎不可用（\(reason)），已改用旧引擎") }
                }
            }
        } else {
            legacy(seg, note: nil)
        }
    }

    // MARK: 旧引擎

    private func legacy(_ seg: Segment, note: String?) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)), rec.isAvailable else {
            Store.shared.updateSegment(seg.id) { $0.status = .failed; $0.error = note ?? "语音识别暂不可用" }
            finish()
            return
        }
        let onDevice = rec.supportsOnDeviceRecognition
        if !onDevice && !Self.allowServer {
            Store.shared.updateSegment(seg.id) {
                $0.status = .blocked
                $0.error = "该语言在这台设备上不支持端侧识别。可在设置中允许使用 Apple 服务器转写。"
            }
            finish()
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: Store.shared.audioURL(seg.id))
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = Self.vocabulary
        recognizer = rec
        var finished = false
        task = rec.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let lines = Self.makeLines(result.bestTranscription, segment: seg)
                    Store.shared.setLines(lines, for: seg.id)
                    Store.shared.updateSegment(seg.id) { $0.status = lines.isEmpty ? .noSpeech : .done; $0.error = note }
                    self.finish()
                } else if let error {
                    finished = true
                    let ns = error as NSError
                    let noSpeech = ns.code == 1110 || ns.localizedDescription.lowercased().contains("no speech")
                    Store.shared.updateSegment(seg.id) {
                        $0.status = noSpeech ? .noSpeech : .failed
                        $0.error = noSpeech ? note : ns.localizedDescription
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !self.busy && !DigestCoordinator.shared.working { self.endBackground() }
        }
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

// MARK: 新引擎（iOS 26+）

@available(iOS 26.0, *)
enum ModernSpeech {
    struct Unsupported: LocalizedError {
        var errorDescription: String? { "所选语言暂不支持" }
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> [(Double, String)] {
        var out: [(Double, String)] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append((result.range.start.seconds, text)) }
        }
        return out
    }

    static func transcribe(url: URL, segment: Segment, localeID: String, vocabulary: [String]) async throws -> [Line] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw Unsupported()
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // 首次使用会下载该语言的端侧模型
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        async let collected = collect(transcriber)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let parts = try await collected
        return parts.map { offset, text in
            let safe = offset.isFinite ? max(0, offset) : 0
            return Line(id: UUID(), segmentID: segment.id, time: segment.start.addingTimeInterval(safe),
                        offset: safe, text: text, edited: false)
        }
    }
}

extension Notification.Name {
    static let transcriptChanged = Notification.Name("transcriptChanged")
}
