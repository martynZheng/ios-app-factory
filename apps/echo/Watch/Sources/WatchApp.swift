import SwiftUI

@main
struct EchoWatchApp: App {
    @StateObject private var recorder = Recorder.shared
    @StateObject private var sync = Sync.shared

    init() {
        Sync.shared.activate()
        Nudges.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            RecorderView()
                .environmentObject(recorder)
                .environmentObject(sync)
        }
    }
}

struct RecorderView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var sync: Sync
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if recorder.state == .idle { idle } else { active }
            }
            .navigationTitle("拾言")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("提示", isPresented: Binding(get: { recorder.notice != nil }, set: { if !$0 { recorder.notice = nil } })) {
            Button("好", role: .cancel) { recorder.notice = nil }
        } message: {
            Text(recorder.notice ?? "")
        }
    }

    // MARK: 未录音

    private var idle: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button {
                    recorder.start()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(.system(size: 30, weight: .semibold))
                        Text("开始录音").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(sync.capturePaused)
                .accessibilityHint("开始后手表会显示系统麦克风指示")

                if sync.capturePaused {
                    Label("已在 iPhone 上暂停采集", systemImage: "pause.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                syncStatus
                NavigationLink {
                    ReminderSettings()
                } label: {
                    Label("提醒与选项", systemImage: "bell")
                }
                .font(.footnote)
                Text("请在对方知情同意的情况下录音。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
        }
    }

    private var syncStatus: some View {
        Group {
            if sync.pending > 0 {
                Label("\(sync.pending) 段待同步到 iPhone", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("已全部同步", systemImage: "checkmark.circle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: 录音中 / 已暂停

    private var active: some View {
        let recording = recorder.state == .recording
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(recording ? Color.red : Color.yellow)
                    .frame(width: 10, height: 10)
                Text(recording ? "正在录音" : "已暂停")
                    .font(.headline)
                    .foregroundStyle(recording ? Color.red : Color.yellow)
            }
            .accessibilityElement(children: .combine)

            Text(timeText(recorder.elapsed))
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("已录 \(Int(recorder.elapsed) / 60) 分 \(Int(recorder.elapsed) % 60) 秒")

            ProgressView(value: recording ? recorder.level : 0)
                .tint(.red)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Button {
                    recording ? recorder.pause() : recorder.resume()
                } label: {
                    Image(systemName: recording ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .tint(.yellow)
                .accessibilityLabel(recording ? "暂停" : "继续")

                Button {
                    recorder.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .tint(.red)
                .accessibilityLabel("结束并保存")

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .accessibilityLabel("删除本次录音")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 4)
        .confirmationDialog("删除本次录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除（含已同步部分）", role: .destructive) { recorder.deleteCurrent() }
            Button("取消", role: .cancel) {}
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct ReminderSettings: View {
    @EnvironmentObject private var recorder: Recorder
    @AppStorage("morningEnabled") private var enabled = false
    @AppStorage("morningHour") private var hour = 8
    @AppStorage("morningMinute") private var minute = 30

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            hour = c.hour ?? 8
            minute = c.minute ?? 30
            Nudges.shared.scheduleMorning()
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("每天提醒我开始", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { Nudges.shared.requestAuth { Nudges.shared.scheduleMorning() } } else { Nudges.shared.scheduleMorning() }
                    }
                if enabled {
                    DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("到点手表会震动，点通知上的「开始录音」即可。录音中断或暂停太久时也会震动提醒你继续。")
            }
            Section {
                Toggle("跳过无声分段", isOn: $recorder.skipSilence)
            } footer: {
                Text("整段 1 分钟几乎没有声音时不同步。可能误丢很小声的对话。")
            }
        }
        .navigationTitle("提醒与选项")
    }
}
