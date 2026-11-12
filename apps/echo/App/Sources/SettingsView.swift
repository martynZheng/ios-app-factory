import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var sync: PhoneSync
    @EnvironmentObject private var transcriber: Transcriber
    @Environment(\.dismiss) private var dismiss

    @AppStorage("capturePaused") private var capturePaused = false
    @AppStorage("speechLocale") private var speechLocale = "zh-CN"
    @AppStorage("allowServerSpeech") private var allowServerSpeech = false
    @AppStorage("vocab") private var vocab = ""
    @AppStorage("aboutMe") private var aboutMe = ""
    @AppStorage("digestEngine") private var engine = "rules"
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @AppStorage("cloudURL") private var cloudURL = ""
    @AppStorage("cloudModel") private var cloudModel = ""
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyPreview") private var notifyPreview = false
    @AppStorage("notifyHour") private var notifyHour = 21
    @AppStorage("notifyMinute") private var notifyMinute = 30
    @AppStorage("appLock") private var appLock = false
    @AppStorage("retentionDays") private var retentionDays = 30

    @State private var cloudKey = Keychain.get("cloudKey") ?? ""
    @State private var exportURL: URL?
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                speechSection
                digestSection
                notifySection
                privacySection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var captureSection: some View {
        Section {
            Toggle("暂停采集", isOn: $capturePaused)
                .onChange(of: capturePaused) { _, paused in sync.pushCapturePaused(paused) }
            LabeledContent("Apple Watch", value: sync.watchStatus)
        } header: {
            Text("采集")
        } footer: {
            Text("暂停后，手表上的「开始录音」会被禁用，直到你在这里恢复。录音只能由你在手表上手动开始，期间手表会显示系统麦克风指示。请只在在场的人知情并同意时录音。")
        }
    }

    private var speechSection: some View {
        Section {
            Picker("识别语言", selection: $speechLocale) {
                Text("普通话").tag("zh-CN")
                Text("粤语").tag("zh-HK")
                Text("English").tag("en-US")
            }
            .onChange(of: speechLocale) { _, _ in transcriber.retryAll() }
            LabeledContent("识别引擎", value: Transcriber.modernAvailable ? "新版端侧（SpeechAnalyzer）" : "旧版端侧")
            TextField("常用词：人名、项目名、术语，用逗号隔开", text: $vocab, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("端侧不可用时使用 Apple 服务器", isOn: $allowServerSpeech)
                .onChange(of: allowServerSpeech) { _, _ in transcriber.retryAll() }
        } header: {
            Text("转写")
        } footer: {
            Text("默认只在本机转写，音频不离开设备。开启此开关后，仅当所选语言不支持端侧识别时，录音会发送给 Apple 的语音识别服务处理（受 Apple 隐私政策约束）。")
        }
    }

    private var digestSection: some View {
        Section {
            TextField("关于我：名字、角色，如：汯毅，供应链 AI 负责人", text: $aboutMe, axis: .vertical)
                .lineLimit(1...3)
            Picker("总结方式", selection: $engine) {
                Text("规则提取（本机）").tag("rules")
                Text("端侧模型（本机）").tag("device")
                Text("云端模型").tag("cloud")
            }
            if engine == "device" {
                LabeledContent("端侧模型", value: DigestEngine.deviceModelAvailable() ? "可用" : "当前不可用")
            }
            if engine == "cloud" {
                Toggle("启用云端总结", isOn: $cloudEnabled)
                Button("填入 DeepSeek 预设") {
                    cloudURL = "https://api.deepseek.com"
                    cloudModel = "deepseek-chat"
                }
                TextField("服务地址（https://…/v1）", text: $cloudURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("模型名", text: $cloudModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API 密钥", text: $cloudKey)
                    .onChange(of: cloudKey) { _, value in Keychain.set(value, for: "cloudKey") }
            }
        } header: {
            Text("回顾与待办")
        } footer: {
            Text(digestFooter)
        }
    }

    private var digestFooter: String {
        switch engine {
        case "device": return "使用系统自带的端侧大模型，转写文字不离开设备。需要系统支持并已启用 Apple 智能。"
        case "cloud": return "启用后，生成回顾时会把当天的转写文字（不含音频）发送到你填写的服务地址，由该服务方按其条款处理和保留；本 App 不经过任何其他服务器。密钥只保存在本机钥匙串。关闭开关即停止上传。"
        default: return "只用关键词规则在本机挑出像决定、待办的原句，不会生成任何原话之外的内容；可能漏掉或多挑，需要你过目。"
        }
    }

    private var notifySection: some View {
        Section {
            Toggle("每日回顾通知", isOn: $notifyEnabled)
                .onChange(of: notifyEnabled) { _, _ in Notifier.apply() }
            if notifyEnabled {
                DatePicker("时间", selection: notifyTime, displayedComponents: .hourAndMinute)
                Toggle("在通知里预览待办", isOn: $notifyPreview)
                    .onChange(of: notifyPreview) { _, _ in Notifier.apply() }
            }
        } header: {
            Text("通知")
        } footer: {
            Text("默认通知里不显示任何对话内容。开启预览后，锁屏上可能出现第一条待办的文字。")
        }
    }

    private var notifyTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: notifyHour, minute: notifyMinute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            notifyHour = c.hour ?? 21
            notifyMinute = c.minute ?? 30
            Notifier.apply()
        })
    }

    private var privacySection: some View {
        Section {
            Toggle("用面容 ID / 密码锁定", isOn: $appLock)
            Picker("音频保留", selection: $retentionDays) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("永久").tag(0)
            }
            LabeledContent("音频占用", value: ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
            if let exportURL {
                ShareLink(item: exportURL) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
            } else {
                Button("导出全部转写与回顾") { exportURL = store.exportFile() }
            }
            Button("删除全部数据", role: .destructive) { confirmDeleteAll = true }
        } header: {
            Text("隐私与数据")
        } footer: {
            Text("所有录音和文字只保存在这台 iPhone 上，由系统数据保护加密（开机后首次解锁前无法读取），并会随 iPhone 的系统备份一起备份。App 本身不向任何服务器上传，除非你在上面主动开启。超过保留期的音频会自动删除，文字保留。")
        }
        .confirmationDialog("删除全部录音、转写和回顾？此操作无法撤销。", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                store.deleteAll()
                exportURL = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var aboutSection: some View {
        Section("已知限制") {
            Text("• 手表录音必须由你在前台手动开始；被来电等打断后，需要抬腕点「继续」。\n• 录音约每分钟同步一段；手机 App 在后台时系统只给很短的处理时间，积压的内容会在你打开 App 时补上。\n• 不区分说话人，负责人只在对话里明确说出时才会填写。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
