import SwiftUI

/// 能力与连接器：它现在会什么，以及怎么给它接上更多。
struct AbilitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connectors = Connectors.shared
    @AppStorage("deepseekHarness") private var harness = true
    @State private var adding = false
    @AppStorage("myShortcuts") private var shortcuts = ""
    @State private var grantStatus: String?
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    private struct Ability: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let on: Bool
    }

    private var abilities: [Ability] {
        let deepseek = Cloud.ready && Cloud.isDeepSeek
        let cloud = Cloud.ready
        return [
            Ability(id: "memory", symbol: "waveform", title: "你的一天", detail: "手表录下的对话、整理出的章节、待办，都能查", on: true),
            Ability(id: "context", symbol: "location", title: "位置、状态、日程", detail: "在哪、在走路还是坐车、接下来有什么（设置 › 情境感知里开）", on: ContextSensor.calendarOn || UserDefaults.standard.bool(forKey: "senseLocation")),
            Ability(id: "search", symbol: "globe", title: "联网搜索、读网页", detail: "查最新的消息并给出来源", on: deepseek),
            Ability(id: "vision", symbol: "photo", title: "看图", detail: "拍照或选图，识别内容和文字", on: cloud),
            Ability(id: "files", symbol: "doc.text", title: "读文件", detail: "PDF（含扫描件）、Word、PPT、表格、电子书", on: deepseek),
            Ability(id: "chart", symbol: "chart.xyaxis.line", title: "画图", detail: "把查到的数据画成折线、面积、柱状图，支持左右双轴", on: cloud),
            Ability(id: "voice", symbol: "mic", title: "听和说", detail: "点麦克风直接说；回答可以读给你听", on: deepseek),
            Ability(id: "memory2", symbol: "brain", title: "长期记忆", detail: "顶层 → 维基 → 笔记 → 原始记录，按需逐层翻；每晚整理一次", on: true),
            Ability(id: "act", symbol: "checklist", title: "提醒事项、日历、定时通知", detail: "写入前都要你点确认", on: true),
            Ability(id: "push", symbol: "sparkles", title: "主动找你", detail: "到点的事提醒你；按你的话题推送资讯", on: cloud),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(abilities) { a in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: a.symbol)
                                .font(.system(size: 16))
                                .foregroundStyle(a.on ? Ink.ink : Ink.ink3)
                                .frame(width: 26, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(.body).foregroundStyle(a.on ? Ink.ink : Ink.ink3)
                                Text(a.on ? a.detail : a.detail + "（还没开启）").font(.footnote).foregroundStyle(Ink.ink3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    LabeledContent("智能体内核", value: Brain.usingPi ? "Pi（原版，\(PiRuntime.shared.version)）" : "内置循环（Pi 未加载）")
                        .font(.footnote)
                    if Cloud.isDeepSeek {
                        Toggle("联网研究用 DeepSeek 的搜索智能体", isOn: $harness)
                            .font(.footnote)
                    }
                } header: {
                    Text("自带的能力")
                } footer: {
                    if !(Cloud.ready && Cloud.isDeepSeek) {
                        Text("搜索、文件解析、语音需要接上 DeepSeek：在对话页粘贴密钥即可。")
                    } else {
                        Text("循环和本机工具由 Pi 负责。要不要上网由它自己判断：需要时调用“联网研究”工具，交给 DeepSeek 服务端的搜索智能体多步搜索、打开网页核实（和 DeepSeek App 的深度思考搜索是同一套），简单问题约 3 秒，要核实的数据约 10–30 秒。关掉后改为它自己逐次调用搜索接口。")
                    }
                }
                phoneSection
                Section {
                    ForEach(connectors.list) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(c.name, isOn: Binding(get: { c.enabled }, set: { connectors.setEnabled(c.id, $0) }))
                            Text(status(c))
                                .font(.caption)
                                .foregroundStyle(c.lastError == nil ? Color.secondary : Ink.vermilion)
                            Button("重新连接") { Task { await connectors.refresh(c.id) } }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                        .swipeActions { Button("删除", role: .destructive) { connectors.remove(c.id) } }
                    }
                    Button { adding = true } label: { Label("添加连接器", systemImage: "plus") }
                } header: {
                    Text("连接器")
                } footer: {
                    Text("接入一个远程 MCP 服务（https 地址，可选访问令牌），它就能用那边的工具：邮箱、知识库、工单、云盘、智能家居……令牌只存在本机钥匙串。它自己醒来找你时，只会用服务方标明“只读”的工具。")
                }
            }
            .navigationTitle("能力与连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $adding) { addSheet }
        }
        .tint(Ink.ink)
    }

    private var phoneSection: some View {
        Section {
            grantRow("heart", "健康", "步数、睡眠、心率、体能训练（只读）") {
                await PhoneApps.shared.healthAccess() ?? "已请求。在“健康”里可随时改：设置 › 健康 › 数据访问与设备 › 拾言。"
            }
            grantRow("calendar", "日历", "查看、新建、修改；删除要你确认") {
                await PhoneApps.shared.calendarAccess() ? "日历已授权。" : "没授权。到系统设置 › 拾言 › 日历，选“完全访问”。"
            }
            grantRow("checklist", "提醒事项", "查看、新建、勾掉；删除要你确认") {
                await PhoneApps.shared.remindersAccess() ? "提醒事项已授权。" : "没授权。到系统设置 › 拾言 › 提醒事项，选“完全访问”。"
            }
            grantRow("person.crop.circle", "通讯录", "按名字查电话、邮箱、生日（只读）") {
                await PhoneApps.shared.contactsAccess() ? "通讯录已授权。" : "没授权。到系统设置 › 拾言 › 通讯录打开。"
            }
            if let grantStatus {
                Text(grantStatus).font(.footnote).foregroundStyle(Ink.ink2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("我的快捷指令").font(.subheadline)
                TextField("每行一个：名字 — 用途。如：记一笔账 — 输入金额和用途，记到钱迹", text: $shortcuts, axis: .vertical)
                    .font(.footnote)
                    .lineLimit(2...8)
            }
            .padding(.vertical, 2)
        } header: {
            Text("手机里的应用")
        } footer: {
            Text("iOS 不允许一个 App 直接读别的 App。官方的健康、日历、提醒事项、通讯录用系统授权接入；其他 App（记账、笔记、智能家居、打车……）通过你的“快捷指令”接入：在快捷指令 App 里做好，把名字写在上面，它就能运行并拿回结果。它还能直接打开链接和 App（导航、打电话、微信……）。备忘录、信息、微信聊天记录这类数据，系统不开放读取。")
        }
    }

    private func grantRow(_ symbol: String, _ title: String, _ detail: String, action: @escaping () async -> String) -> some View {
        Button {
            Task { grantStatus = await action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 26).foregroundStyle(Ink.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Ink.ink)
                    Text(detail).font(.footnote).foregroundStyle(Ink.ink3)
                }
                Spacer()
                Text("授权").font(.footnote).foregroundStyle(Ink.ink2)
            }
        }
    }

    private func status(_ c: Connector) -> String {
        if let error = c.lastError { return error }
        if c.tools.isEmpty { return "还没读到工具，点“重新连接”" }
        let names = c.tools.prefix(4).map { $0.name }.joined(separator: "、")
        return "\(c.tools.count) 个工具：\(names)"
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("名字，如：我的邮箱", text: $name)
                TextField("MCP 地址（https://…）", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("访问令牌（可选）", text: $token)
            }
            .navigationTitle("添加连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        let c = connectors.add(name: name.isEmpty ? "连接器" : name, url: url, token: token)
                        name = ""; url = ""; token = ""
                        adding = false
                        Task { await connectors.refresh(c.id) }
                    }
                    .disabled(!url.lowercased().hasPrefix("https://"))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
