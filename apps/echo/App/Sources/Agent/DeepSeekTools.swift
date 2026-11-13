import Foundation

/// 云端服务的配置（地址、模型、密钥都由用户在 App 里填，密钥只在钥匙串）。
enum Cloud {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "cloudEnabled") }
    static var base: String { (UserDefaults.standard.string(forKey: "cloudURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var modelName: String { (UserDefaults.standard.string(forKey: "cloudModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var key: String { Keychain.get("cloudKey") ?? "" }
    static var ready: Bool { enabled && !base.isEmpty && !modelName.isEmpty && !key.isEmpty }
    static var isDeepSeek: Bool { base.contains("deepseek.com") }

    /// 一步配置好 DeepSeek。
    static func setupDeepSeek(key: String) {
        let d = UserDefaults.standard
        d.set("https://api.deepseek.com", forKey: "cloudURL")
        d.set("deepseek-flash", forKey: "cloudModel")
        d.set(true, forKey: "cloudEnabled")
        d.set("cloud", forKey: "digestEngine")
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "cloudKey")
    }

    /// 旧预设用的模型名已经换代：DeepSeek 现在的模型是 deepseek-flash。
    static func migrate() {
        let d = UserDefaults.standard
        if isDeepSeek, d.string(forKey: "cloudModel") == "deepseek-chat" { d.set("deepseek-flash", forKey: "cloudModel") }
    }

    static func model() throws -> ChatModel {
        guard ready else { throw DigestError.unavailable("还没有配置云端智能体：在对话页粘贴 DeepSeek 密钥，或到设置里填写。") }
        return OpenAICompatModel(baseURL: base, model: modelName, apiKey: key)
    }

    /// 服务根地址（去掉结尾的 /v1）。
    private static var root: String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return b
    }

    static func post(path: String, body: [String: Any], timeout: TimeInterval = 40) async throws -> [String: Any] {
        guard let url = URL(string: root + path), url.scheme == "https" else { throw DigestError.unavailable("云端服务地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 402 { throw DigestError.unavailable("DeepSeek 账户余额不足（HTTP 402）。") }
            throw DigestError.unavailable("请求失败（HTTP \(code)）。")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// 联网搜索（DeepSeek /v1/tools/search）。返回给模型读的文字和给界面用的来源。
    static func search(_ query: String, question: String?) async throws -> (String, [WebSource]) {
        var body: [String: Any] = ["query": String(query.prefix(128)), "count": 6]
        if let question, !question.isEmpty { body["ori_question"] = String(question.prefix(500)) }
        let obj = try await post(path: "/v1/tools/search", body: body)
        let results = obj["results"] as? [[String: Any]] ?? []
        var rows: [String] = []
        var sources: [WebSource] = []
        for (i, r) in results.enumerated() {
            let title = r["title"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            let site = r["site_name"] as? String ?? ""
            let date = (r["date"] as? String).map { String($0.prefix(10)) } ?? ""
            let summary = (r["summary"] as? String) ?? (r["snippet"] as? String) ?? ""
            rows.append("[\(i + 1)] \(title)（\(site) \(date)）\n\(url)\n\(String(summary.prefix(600)))")
            if !url.isEmpty { sources.append(WebSource(title: title.isEmpty ? url : title, url: url, site: site)) }
        }
        return (rows.isEmpty ? "没有搜到结果。" : rows.joined(separator: "\n\n"), sources)
    }

    /// 抓取网页正文（DeepSeek /v1/tools/fetch）。
    static func fetch(_ url: String) async throws -> String {
        let obj = try await post(path: "/v1/tools/fetch", body: ["url": url], timeout: 60)
        let title = obj["title"] as? String ?? ""
        let content = obj["content"] as? String ?? ""
        return "# \(title)\n\(String(content.prefix(12_000)))"
    }
}

struct WebSource: Codable, Hashable {
    var title: String
    var url: String
    var site: String
}
