import Foundation

// MARK: - 端到端管线：判断 → 军师推演 → 起草（每档 1 条 / 每话术 2 条）→ 排序
//
// 阶段间的关系：**判断与军师推演同时起跑**（两者互不依赖，串起来就是白等一次往返），
// 起草等军师——军师要定三档口径，候选才有个谱。
// 两级回退都在：判断超时/没配 key → 盲起草（意图只影响排序与军师）；军师挂了 → 退回按话术槽起草，
// 行为与本功能引入前完全一致。排序失败按「每个档位的第 1 条在前」的默认顺序展示。

struct Candidate: Identifiable, Equatable {
    var id: String { text }
    var text: String
    /// 话术名，或军师三档模式下是档位名（稳健/会撩/强势）
    var tone: String
    /// Jev 排序概率；没排序时为 nil
    var prob: Double?
}

struct Analysis: Equatable {
    var message: String
    var judge: JudgeResult?
    /// 狗头军师推演结果（没开、或推演失败退回时为 nil）
    var junshi: JunshiAnalysis?
    var candidates: [Candidate] = []
    /// 非致命错误（某话术失败、排序失败），界面黄条展示
    var notices: [String] = []
    /// 致命错误（生成层全挂），界面红条展示
    var fatalError: String?
    var elapsed: Double = 0
    /// 候选已经出来了、但排序还没回来（界面据此提示"排序中"，并允许先点候选）
    var rankingPending: Bool = false
}

enum PipelineStage: Equatable {
    case judging
    /// 军师推演（局面 / 利弊 / 首选 / 风险 + 三档口径）
    case weighing
    case drafting(done: Int, total: Int)
    case ranking
    case done
}

final class JevPipeline {
    private let cfg: JevConfig
    private let judge: JevJudge
    private let draft: JevDraft
    private let junshi: JevJunshi
    private let language: JevLanguage

    init(cfg: JevConfig) {
        self.cfg = cfg
        self.judge = JevJudge(cfg: cfg)
        self.draft = JevDraft(cfg: cfg)
        self.junshi = JevJunshi(cfg: cfg)
        self.language = JevStore.loadLanguage()
    }

    var generationConfigured: Bool { draft.isConfigured }

    /// 完整分析。永不 throw：致命问题进 fatalError，其余进 notices。
    ///
    /// 时间预算上的取舍（实测：模型服务每次请求光"出第一个字"就要 1.5 秒上下，
    /// 而且两条并发请求是真并发、不被排队），所以**减少串行等待**比压缩单次耗时更有效：
    ///   · 判断结果按消息缓存：同一条消息再分析（主要是「换一批」）不再花那次往返；
    ///   · 判断与军师并行起跑，不串成两段等待；
    ///   · 每条档位的候选一到就通过 onPartial 交给界面，不等其余档位、更不等排序。
    func analyze(message: String, context: String?,
                 onStage: ((PipelineStage) -> Void)? = nil,
                 onPartial: ((Analysis) -> Void)? = nil) async -> Analysis {
        let start = Date()
        var out = Analysis(message: message)

        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            out.fatalError = JevStore.loadLanguage() == .english
                ? "The message is empty. Long-press the message in your chat app and tap Copy, or type it into the field"
                : "消息内容为空：请先在聊天里长按消息点「复制」，或把要回的话输进输入框"
            return out
        }
        guard JevStore.groupContainerAvailable || KBLocalConfig.hasAny else {
            // 共享通道断了：App 与键盘各持一个私有容器，配置永远传不过去。
            // 这时候提示「去填 Key」是死路——必须先修签名。
            out.fatalError = JevStore.loadLanguage() == .english
                ? "Shared container unavailable: this install's signature lacks the App Group entitlement, so the keyboard cannot read the app's config. Re-sign with Sideloadly (keep App Group support on) and reinstall"
                : "共享容器不可用：这次安装的签名没带上 App Group 权限，键盘读不到 App 的配置。请用 Sideloadly 重签安装（保持 App Group 支持开启）后重试"
            return out
        }
        guard draft.isConfigured else {
            out.fatalError = JevStore.loadLanguage() == .english
                ? "Generation layer not configured. Open Jev Jarvis → Models and add an API key"
                : "还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key（兜底：长按键盘 1.5 秒，可直接在键盘里填 Key）"
            return out
        }

        // 1) 判断层：起跑，但**不阻塞起草**。
        //
        // 为什么不串行等它：实测每次请求光"出第一个字"就要 1.5 秒上下，而喂给起草模型的那句
        // "意图"只是一个标签（真正决定候选风格的是档位/话术指令）——A/B 实测盲起草与带意图起草的
        // 候选几乎没差别。所以让判断与起草重叠，意图的作用由「排序」这一层体现。
        //
        // 同一条消息的判断结果带缓存：换一批时连这一次都不用跑。
        var judgeResult = judge.isConfigured
            ? JevJudgeCache.shared.get(message: msg, context: context)
            : nil
        var judgeTask: Task<JudgeResult?, Never>?
        if judge.isConfigured, judgeResult == nil {
            onStage?(.judging)
            judgeTask = Task { [judge] in
                let r = try? await judge.judge(message: msg, context: context)
                if let r { JevJudgeCache.shared.put(r, message: msg, context: context) }
                return r
            }
        }

        // 1b) 军师推演：与判断并行起跑。它决定三档口径，所以起草要等它——
        // 但有硬超时（25 秒）兜着，不会把键盘一直吊在那儿。
        var junshiResult: JunshiAnalysis?
        if cfg.junshi, junshi.isConfigured {
            onStage?(.weighing)
            do {
                junshiResult = try await withTimeout(seconds: 25) {
                    try await self.junshi.weigh(message: msg, context: context)
                }
            } catch {
                junshiResult = nil
                out.notices.append(language == .english
                    ? "Strategist weigh-in failed; drafting from your tone slots instead"
                    : "军师推演没成功，已按话术槽起草")
            }
        }
        out.junshi = junshiResult
        // 推演是主菜，先把它落上面板，别等候选齐了才一起出现
        if junshiResult != nil {
            var p = out
            p.rankingPending = true
            p.elapsed = Date().timeIntervalSince(start)
            onPartial?(p)
        }

        // 2) 起草：军师在 → 稳健/会撩/强势三档，每档 1 条；
        //           否则 → 用户选的话术槽，每槽 2 条（一个槽一次请求，并发）。
        let tones = allTones(custom: cfg.customTones)
        var active: [(String, String)]
        var perTone = PER_TONE
        var strategyMode = false
        if let js = junshiResult, !js.versions.isEmpty {
            strategyMode = true
            perTone = 1
            active = js.versions.map { ($0.strategy, junshiInstruction($0, language: language)) }
        } else {
            active = cfg.activeSlots.compactMap { name -> (String, String)? in
                guard let instruction = tones[name] else { return nil }
                return (name, instruction)
            }
        }
        guard !active.isEmpty else {
            out.fatalError = JevStore.loadLanguage() == .english
                ? "Every tone slot is off. Open the app → Tones and enable at least one"
                : "所有话术槽都是「不用」：打开 App →「话术」页至少启用一个"
            out.elapsed = Date().timeIntervalSince(start)
            return out
        }

        // 判断命中缓存时，第一轮就直接带意图（不用等，也没损失）
        let firstIntent = judgeResult?.intent
        func partial(with round: DraftRound, judge: JudgeResult?, extraNotices: [String] = []) -> Analysis {
            var p = out
            p.judge = judge
            p.candidates = Self.ordered(active.map(\.0), round.candidates)
            p.notices = out.notices + round.notices + extraNotices
            p.rankingPending = true
            p.elapsed = Date().timeIntervalSince(start)
            return p
        }

        onStage?(.drafting(done: 0, total: active.count))
        var round = await draftRound(active: active, msg: msg, intent: firstIntent, context: context,
                                     perTone: perTone, strategyMode: strategyMode,
                                     onStage: onStage) { r in
            onPartial?(partial(with: r, judge: JevJudgeCache.shared.get(message: msg, context: context)))
        }
        out.notices += round.notices
        var drafted = round.candidates

        // 判断落地：给排序用。等它有时间上限，别让一个卡住的上游拖住整条链路。
        if let t = judgeTask, judgeResult == nil {
            judgeResult = try? await withTimeout(seconds: 4) { await t.value }
        }
        out.judge = judgeResult
        if judge.isConfigured, judgeResult == nil {
            out.notices.append(JevStore.loadLanguage() == .english
                ? "Judge layer unavailable; drafted without intent. Tap 🔑 Enter API key to fill the judge key too."
                : "判断层没响应，已盲起草（不影响出候选）。点「🔑 在键盘里填 API Key」可以把判断层的 Key 一起补上。")
        }

        // 2b) 高风险消息才用意图重写一版。**只在军师没接管时做**：军师那套三档口径本身就是
        // 按"这一步的利弊"定的，风险高的情况下它已经给了更贴的答案，再花一次往返不划算。
        if junshiResult == nil, let jr = judgeResult, firstIntent == nil,
           jr.risk >= Self.refineRiskThreshold, !drafted.isEmpty {
            let note = String(format: "风险 %.0f/9：已按判断重写一版候选", jr.risk)
            round = await draftRound(active: active, msg: msg, intent: jr.intent, context: context,
                                     perTone: perTone, strategyMode: strategyMode,
                                     onStage: onStage) { r in
                onPartial?(partial(with: r, judge: jr, extraNotices: [note]))
            }
            if !round.candidates.isEmpty {
                drafted = round.candidates
                out.notices += round.notices
                out.notices.append(note)
            }
        }

        guard !drafted.isEmpty else {
            out.fatalError = out.notices.first ?? (JevStore.loadLanguage() == .english
                ? "Candidate generation failed. Open the app → Models and run Test connection to check your setup"
                : "候选生成失败：请到 App「模型」页点「测试连接」检查配置")
            out.elapsed = Date().timeIntervalSince(start)
            return out
        }

        // 3) 排序（可选）。失败按默认顺序：同档位的稳妥款在前。
        let ordered = Self.ordered(active.map(\.0), drafted)
        if judge.isConfigured, let jr = judgeResult {
            onStage?(.ranking)
            if let ranked = try? await withTimeout(seconds: 10, {
                try await self.judge.rank(message: msg, intent: jr.intent,
                                          candidates: ordered.map(\.text))
            }) {
                // 同一句话可能被两个档位各出一条（去重前不能拿它当字典的唯一 key，会 trap）。
                let toneBy = Dictionary(ordered.map { ($0.text, $0.tone) },
                                        uniquingKeysWith: { first, _ in first })
                let mapped = ranked.compactMap { r -> Candidate? in
                    guard let tone = toneBy[r.text] else { return nil }
                    return Candidate(text: r.text, tone: tone, prob: r.prob)
                }
                if mapped.isEmpty {
                    // 排序层回传的文本和候选对不上（模型改写了标点/空格）——宁可退回未排序的全量候选，
                    // 也不能让界面变成「判断头 + 一片空白」。
                    out.notices.append(JevStore.loadLanguage() == .english
                        ? "Ranking didn't match the candidates; showing default order"
                        : "排序结果和候选对不上，已按默认顺序展示")
                    out.candidates = ordered
                } else {
                    out.candidates = mapped
                }
            } else {
                out.notices.append(JevStore.loadLanguage() == .english
                    ? "Ranking failed; showing default order"
                    : "排序失败，按默认顺序展示")
                out.candidates = ordered
            }
        } else {
            out.candidates = ordered
        }

        out.elapsed = Date().timeIntervalSince(start)
        onStage?(.done)
        return out
    }

    /// 按档位/话术槽的顺序整理候选（每个槽内部保持模型给出的顺序：前稳后放）
    private static func ordered(_ tones: [String], _ drafted: [Candidate]) -> [Candidate] {
        tones.flatMap { name in drafted.filter { $0.tone == name } }
    }

    /// 风险达到这个分数才值得用意图重写候选（0-9 分制，6 起是"需要谨慎"那一档）。
    /// 平常用消息不花这一次往返——实测盲起草与带意图起草的候选差别很小。
    private static let refineRiskThreshold: Double = 6

    /// 一轮起草的结果
    struct DraftRound {
        var candidates: [Candidate] = []
        var notices: [String] = []
    }

    /// 跑一轮起草：每个档位/话术一次请求（并发），每完成一个就把"到目前为止的候选"交给界面。
    private func draftRound(active: [(String, String)], msg: String, intent: String?, context: String?,
                            perTone: Int, strategyMode: Bool,
                            onStage: ((PipelineStage) -> Void)?,
                            onPartial: @escaping (DraftRound) -> Void) async -> DraftRound {
        var round = DraftRound()
        await withTaskGroup(of: (String, [String], String?).self) { group in
            for (name, instruction) in active {
                group.addTask {
                    do {
                        let texts = try await self.draft.draft(
                            message: msg, intent: intent, context: context,
                            tone: name, instruction: instruction,
                            n: perTone, strategyMode: strategyMode)
                        return (name, texts, nil)
                    } catch {
                        return (name, [], error.localizedDescription)
                    }
                }
            }
            var done = 0
            for await (name, texts, err) in group {
                done += 1
                onStage?(.drafting(done: done, total: active.count))
                if let err {
                    round.notices.append(JevStore.loadLanguage() == .english
                        ? "“\(name)” failed: \(err)"
                        : "「\(name)」失败：\(err)")
                }
                for t in texts { round.candidates.append(Candidate(text: t, tone: name, prob: nil)) }
                // 先出一条是一条：不等其余档位、更不等排序
                if !round.candidates.isEmpty { onPartial(round) }
            }
        }
        return round
    }

    // MARK: 超时包装（阶段级截止时间，比预算更硬：到点放弃该阶段而不是拖慢整体）
    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw JevError.timeout("", seconds)
            }
            guard let first = try await group.next() else {
                throw JevError.cancelled
            }
            group.cancelAll()
            return first
        }
    }
}
