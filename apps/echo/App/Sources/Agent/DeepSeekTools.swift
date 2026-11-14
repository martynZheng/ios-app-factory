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

    /// thinking：只对 DeepSeek 生效。nil 用服务端默认（思考），false 关掉思考换速度。
    static func model(thinking: Bool? = nil) throws -> ChatModel {
        guard ready else { throw DigestError.unavailable("还没有配置云端智能体：在对话页粘贴 DeepSeek 密钥，或到设置里填写。") }
        var m = OpenAICompatModel(baseURL: base, model: modelName, apiKey: key)
        if isDeepSeek { m.thinking = thinking }
        return m
    }

    /// 对话接口的完整地址。
    static var chatURL: URL? {
        let b = base
        guard let url = URL(string: b.hasSuffix("/") ? b + "chat/completions" : b + "/chat/completions"), url.scheme == "https" else { return nil }
        return url
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

    // MARK: 语音、文件（DeepSeek 应用 API）

    private static func check(_ response: URLResponse, _ data: Data, what: String) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw DigestError.unavailable("云端密钥无效（HTTP 401）。") }
            if code == 402 { throw DigestError.unavailable("DeepSeek 账户余额不足（HTTP 402）。") }
            if code == 413 { throw DigestError.unavailable("\(what)：文件太大。") }
            var detail = ""
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
                detail = " " + String(message.prefix(120))
            }
            throw DigestError.unavailable("\(what)失败（HTTP \(code)）\(detail)")
        }
    }

    /// multipart/form-data。fields 按顺序写在文件之前（Files API 要求 purpose 在 file 前面）。
    private static func upload(path: String, fields: [(String, String)], filename: String, mime: String, file: Data,
                               timeout: TimeInterval, what: String) async throws -> [String: Any] {
        guard isDeepSeek, let url = URL(string: root + path), url.scheme == "https" else {
            throw DigestError.unavailable("\(what)需要先接上 DeepSeek。")
        }
        let boundary = "echo-" + UUID().uuidString
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try check(response, data, what: what)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// 语音识别（/v1/tools/asr）：16 位 PCM WAV，最长 120 秒，自动识别语种。
    static func transcribe(wav: Data) async throws -> String {
        let obj = try await upload(path: "/v1/tools/asr", fields: [], filename: "speech.wav", mime: "audio/wav", file: wav, timeout: 90, what: "语音识别")
        return (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 语音合成（/v1/tools/tts）：返回 WAV。voice：stella（女声）/ tide（男声）。
    static func speech(_ text: String, voice: String) async throws -> Data {
        guard isDeepSeek, let url = URL(string: root + "/v1/tools/tts") else { throw DigestError.unavailable("语音合成需要先接上 DeepSeek。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["text": text, "voice_id": voice == "tide" ? "tide" : "stella"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data, what: "语音合成")
        return data
    }

    /// 哪些文件交给 DeepSeek 解析（上传到 Files API，在对话里用 file_id 引用）。
    static func parsesRemotely(_ ext: String) -> Bool {
        ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "epub", "mobi"].contains(ext.lowercased())
    }

    /// 上传并解析文档，返回 file_id。文件 30 天后在 DeepSeek 那边自动过期。
    static func uploadDocument(name: String, data: Data) async throws -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let purpose = ["xls", "xlsx", "epub", "mobi"].contains(ext) ? "user_data" : "text_recognition"
        let fields = [("purpose", purpose), ("expires_after[anchor]", "created_at"), ("expires_after[seconds]", "2592000")]
        let obj = try await upload(path: "/files", fields: fields, filename: name, mime: "application/octet-stream", file: data, timeout: 240, what: "文件解析")
        guard let id = obj["id"] as? String, !id.isEmpty else { throw DigestError.unavailable("文件解析没有返回结果。") }
        return id
    }
}

struct WebSource: Codable, Hashable {
    var title: String
    var url: String
    var site: String
}
