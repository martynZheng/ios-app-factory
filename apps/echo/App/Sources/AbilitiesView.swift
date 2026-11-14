import SwiftUI

/// 能力与连接器：它现在会什么，以及怎么给它接上更多。
struct AbilitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connectors = Connectors.shared
    @AppStorage("deepseekHarness") private var harness = true
    @State private var adding = false
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
                        Toggle("联网用 DeepSeek 的深度搜索", isOn: $harness)
                            .font(.footnote)
                    }
                } header: {
                    Text("自带的能力")
                } footer: {
                    if !(Cloud.ready && Cloud.isDeepSeek) {
                        Text("搜索、文件解析、语音需要接上 DeepSeek：在对话页粘贴密钥即可。")
                    } else {
                        Text("循环和本机工具由 Pi 负责；联网搜索、打开网页交给 DeepSeek 服务端自己多步完成（和 DeepSeek App 的深度思考搜索是同一套），通常更快更准。关掉后改用我们自己逐次调用搜索接口。")
                    }
                }
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
