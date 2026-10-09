import Foundation

// MARK: - 生成层：OpenAI / Anthropic 兼容起草客户端
//
// 一个话术一次请求（两话术合在一个 prompt 里会互相渗味，macOS 版实测结论）。
// 两种 API 形状：绝大多数端点（DeepSeek/智谱/通义/Moonshot/硅基/OpenRouter/Ollama）
// 只有 OpenAI 形状；智谱和少数网关两种都有。

final class JevDraft {
    private let cfg: JevConfig

    /// 采样温度。对齐 macOS 版 `src/generate.py` 的 0.9：部分渠道把范围夹在 [0,1]，
    /// 发 1.2 会被上游直接拒（400 temperature参数非法）。
    private static let temperature: Double = 0.9

    init(cfg: JevConfig) {
        self.cfg = cfg
    }

    var isConfigured: Bool {
        let g = cfg.generation
        return !g.key.isEmpty && !g.base.isEmpty && !g.model.isEmpty
    }

    // MARK: URL 拼接
    //
    // base 带不带末尾 /chat/completions、/v1、/v4 都能拼对：
    //   https://api.deepseek.com                -> /chat/completions
    //   https://api.deepseek.com/v1             -> /v1/chat/completions
    //   https://open.bigmodel.cn/api/paas/v4    -> /api/paas/v4/chat/completions
    // Anthropic 形状对版本段单独处理（…/api/anthropic -> /v1/messages）。

    static func chatURL(_ rawBase: String, kind: APIKind) -> String {
        let b = rawBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let segs = b.split(separator: "/").map(String.init)
        guard let last = segs.last?.lowercased() else { return b }
        switch kind {
        case .openai:
            if last == "completions" { return b }
            return b + "/chat/completions"
        case .anthropic:
            if last == "messages" { return b }
            if last.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return b + "/messages" }
            return b + "/v1/messages"
        }
    }

    // MARK: 起草

    /// 一轮起草。n = 这一轮要几条（话术槽模式是 2 条，军师三档模式是每档 1 条）。
    /// strategyMode 换用三档模板——那个模板每次只写一条，跟「两条的胆量要有差别」的话术模板不是一回事。
    /// 失败抛错，由管线层归拢。
    func draft(message: String, intent: String?, context: String?,
               tone: String, instruction: String,
               n: Int = PER_TONE, strategyMode: Bool = false) async throws -> [String] {
        let prompt = buildDraftPrompt(message: message, intent: intent, context: context,
                                      tone: tone, instruction: instruction, n: n,
                                      strategyMode: strategyMode)
        let raw = try await call(prompt: prompt)
        let lines = CandidateParser.parse(raw, limit: n)
        if lines.isEmpty { throw JevError.emptyReply }
        return lines
    }

    /// 起草：单轮 user 提示，400 token 够两句候选。
    func call(prompt: String) async throws -> String {
        try await complete(system: nil, user: prompt, maxTokens: 400,
                           temperature: Self.temperature, budget: 35, stage: "生成")
    }

    /// 通用补全。军师推演复用同一套 transport——它要 system 提示、更长的输出和更宽的预算。
    func complete(system: String?, user: String, maxTokens: Int,
                  temperature: Double, budget: Double, stage: String) async throws -> String {
        let g = cfg.generation
        let url = Self.chatURL(g.base, kind: g.kind)
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        var body: [String: Any]
        var headers = ["Content-Type": "application/json"]
        switch g.kind {
        case .openai:
            body = [
                "model": g.model,
                "messages": messages,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "stream": false,
            ]
            headers["Authorization"] = "Bearer \(g.key)"
        case .anthropic:
            // Anthropic 的 messages 只收 user/assistant，system 是顶层字段
            body = [
                "model": g.model,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "messages": messages,
            ]
            if let system { body["system"] = system }
            headers["x-api-key"] = g.key
            headers["anthropic-version"] = "2023-06-01"
        }
        // 额外字段（关思考模式等）。非法 JSON 直接忽略——不该让一个可选配置打断整条链路。
        let extra = g.extraJSON.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty, let data = extra.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj { body[k] = v }
        }
        let data = try await JevHTTP.postJSON(body, url: url, headers: headers,
                                              budget: budget, stage: stage)
        return try Self.extractText(data, kind: g.kind, model: g.model)
    }

    /// 两种响应形状的正文抽取 + 「思考型模型吃光额度」识别。
    static func extractText(_ data: [String: Any], kind: APIKind, model: String) throws -> String {
        switch kind {
        case .openai:
            let choices = data["choices"] as? [[String: Any]] ?? []
            let msg = choices.first?["message"] as? [String: Any] ?? [:]
            if let text = msg["content"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
            let reasoning = (msg["reasoning_content"] ?? msg["reasoning"]) as? String
            if let r = reasoning, !r.isEmpty {
                throw JevError.thinkingOnly(JevStore.loadLanguage() == .english
                    ? "“\(model)” is a reasoning model: its thinking consumed the budget and returned 0 replies. Switch to a non-reasoning model (e.g. deepseek-chat, glm-4-flash)"
                    : "「\(model)」是思考型模型：思考占满了额度，正文 0 条；请换非思考模型（如 deepseek-chat、glm-4-flash）")
            }
            throw JevError.emptyReply
        case .anthropic:
            let content = data["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
            throw JevError.emptyReply
        }
    }
}
