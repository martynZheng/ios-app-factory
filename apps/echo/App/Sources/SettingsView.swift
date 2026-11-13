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

    @AppStorage("senseLocation") private var senseLocation = false
    @AppStorage("senseMotion") private var senseMotion = false
    @AppStorage("senseCalendar") private var senseCalendar = false
    @ObservedObject private var sensor = ContextSensor.shared
    @ObservedObject private var connectors = Connectors.shared
    @ObservedObject private var chat = ChatStore.shared
    @AppStorage("proactiveEnabled") private var proactiveEnabled = true
    @State private var addingConnector = false
    @State private var connectorName = ""
    @State private var connectorURL = ""
    @State private var connectorToken = ""

    @State private var cloudKey = Keychain.get("cloudKey") ?? ""
    @State private var exportURL: URL?
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                speechSection
                contextSection
                digestSection
                agentSection
                connectorSection
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

    private var contextSection: some View {
        Section {
            Toggle("位置（到访的地点）", isOn: Binding(get: { senseLocation }, set: { on in
                senseLocation = on
                sensor.enableLocation(on)
            }))
            if senseLocation, sensor.locationStatus == .authorizedWhenInUse {
                Text("现在只有“使用 App 期间”的定位权限，后台记不到你去过哪。到「设置 › 拾言 › 位置」改成「始终」。")
                    .font(.footnote).foregroundStyle(Ink.vermilion)
            }
            if senseLocation, sensor.locationStatus == .denied {
                Text("定位权限被关闭了，到「设置 › 拾言 › 位置」打开。").font(.footnote).foregroundStyle(Ink.vermilion)
            }
            Toggle("身体状态（静止 / 步行 / 乘车）", isOn: Binding(get: { senseMotion }, set: { on in
                senseMotion = on
                sensor.enableMotion(on)
            }))
            Toggle("读取日程", isOn: Binding(get: { senseCalendar }, set: { on in
                senseCalendar = on
                Task { let ok = await sensor.enableCalendar(on); if on && !ok { senseCalendar = false } }
            }))
        } header: {
            Text("情境感知")
        } footer: {
            Text("用来判断每段对话发生时你在哪、在干什么（开会、在路上、在家），分章和整理会准很多。位置用的是系统的“到访”检测，很省电；身体状态来自 iPhone 的运动协处理器。这些数据只存在本机；只有开启云端智能体时，地点名称、状态和日程标题（不含坐标）会随转写一起发给它。")
        }
    }

    private var digestSection: some View {
        Section {
            TextField("关于我：名字、角色，如：汯毅，供应链 AI 负责人", text: $aboutMe, axis: .vertical)
                .lineLimit(1...3)
            Picker("总结方式", selection: $engine) {
                Text("规则提取（本机）").tag("rules")
                Text("端侧模型（本机）").tag("device")
                Text("云端智能体").tag("cloud")
            }
            if engine == "device" {
                LabeledContent("端侧模型", value: DigestEngine.deviceModelAvailable() ? "可用" : "当前不可用")
            }
            if engine == "cloud" {
                Toggle("启用云端智能体", isOn: $cloudEnabled)
                Button("填入 DeepSeek 预设") {
                    cloudURL = "https://api.deepseek.com"
                    cloudModel = "deepseek-flash"
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

    private var agentSection: some View {
        Section {
            Toggle("主动提醒", isOn: $proactiveEnabled)
            if chat.memory.isEmpty {
                Text("还没有让它记住的事。在对话里说“记住……”就行。").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(chat.memory, id: \.self) { fact in
                    Text(fact).font(.subheadline)
                        .swipeActions { Button("忘掉", role: .destructive) { chat.forget(fact) } }
                }
            }
            Button("清空对话记录", role: .destructive) { chat.clear() }
        } header: {
            Text("助理")
        } footer: {
            Text("主动提醒：整理出新的一段对话、到了新地点，或系统给后台时间时，助理会自己看一眼有没有值得现在告诉你的事，有才发通知（8 点前和 23 点后不打扰，一天最多 6 条）。iOS 不允许 App 一直在后台运行，所以提醒的时机取决于这些事件。需要已配置云端智能体并允许通知。")
        }
    }

    private var connectorSection: some View {
        Section {
            ForEach(connectors.list) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(c.name, isOn: Binding(get: { c.enabled }, set: { connectors.setEnabled(c.id, $0) }))
                    Text(connectorStatus(c))
                        .font(.caption)
                        .foregroundStyle(c.lastError == nil ? Color.secondary : Ink.vermilion)
                    Button("重新连接") { Task { await connectors.refresh(c.id) } }.font(.caption)
                }
                .swipeActions { Button("删除", role: .destructive) { connectors.remove(c.id) } }
            }
            Button("添加连接器") { addingConnector = true }
        } header: {
            Text("连接器")
        } footer: {
            Text("接入一个远程 MCP 服务（https 地址，可选访问令牌），助理就能调用它提供的工具，比如你自己的知识库、工单、云盘。已内置：联网搜索、读网页、看图、读文件、日程、提醒事项、位置与状态。令牌只存在本机钥匙串。")
        }
        .sheet(isPresented: $addingConnector) {
            NavigationStack {
                Form {
                    TextField("名字，如：我的知识库", text: $connectorName)
                    TextField("MCP 地址（https://…）", text: $connectorURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("访问令牌（可选）", text: $connectorToken)
                }
                .navigationTitle("添加连接器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { addingConnector = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("连接") {
                            let c = connectors.add(name: connectorName.isEmpty ? "连接器" : connectorName, url: connectorURL, token: connectorToken)
                            connectorName = ""; connectorURL = ""; connectorToken = ""
                            addingConnector = false
                            Task { await connectors.refresh(c.id) }
                        }
                        .disabled(!connectorURL.lowercased().hasPrefix("https://"))
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func connectorStatus(_ c: Connector) -> String {
        if let error = c.lastError { return error }
        if c.tools.isEmpty { return "还没读到工具，点“重新连接”" }
        let names = c.tools.prefix(4).map { $0.name }.joined(separator: "、")
        return "\(c.tools.count) 个工具：\(names)"
    }

    private var digestFooter: String {
        switch engine {
        case "device": return "使用系统自带的端侧大模型，转写文字不离开设备。需要系统支持并已启用 Apple 智能。"
        case "cloud": return "云端智能体会先查看当时的情境（地点、状态、日程）、今天前面的经过和以前的记录，推理出你在什么场景，再分章整理；整理结果会经过校验，不合格会退回让它重写。启用后，转写文字（不含音频）和情境文字会发送到你填写的服务地址（推荐 DeepSeek），由该服务方按其条款处理；本 App 不经过任何其他服务器。密钥只保存在本机钥匙串。"
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
                sensor.deleteAll()
                chat.clear()
                chat.forgetAll()
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
