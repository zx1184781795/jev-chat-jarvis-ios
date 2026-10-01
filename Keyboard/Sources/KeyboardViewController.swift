import UIKit

/// Jev 键盘：一个「回复面板」键盘，不是打字键盘。
///
/// 交互闭环（不跳出聊天 App）：
///   ① 在聊天里长按对方消息 → 复制
///   ② 键盘上点「分析剪贴板」→ 意图/风险 + 每话术 2 条候选
///   ③ 点候选 → 直接 insertText 进当前输入框（发送永远由用户手动完成）
///
/// 联网、读剪贴板、读共享配置都要求用户在系统设置里给「允许完全访问」——
/// 这是 iOS 键盘扩展的唯一开关，没有别的权限可申请。
final class KeyboardViewController: UIInputViewController {

    private var language: JevLanguage { JevStore.loadLanguage() }

    private func L(_ zh: String, _ en: String) -> String {
        jevLocalized(language, zh: zh, en: en)
    }

    private enum Mode { case gate, idle, tones, loading, result, error }

    private var mode: Mode = .idle
    private var lastSource: Source = .clipboard
    private var lastMessage: String = ""
    private var analysis: Analysis?
    private var errorText: String = ""
    private var stageLabel = UILabel()

    private enum Source { case clipboard, inputField }

    // MARK: 布局骨架

    private let topBar = UIView()
    private var statusLabel = UILabel()
    private let contentStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    /// 当前状态里参与「按内容定高」的块，顺序即纵向顺序。
    /// 候选区放的是内部列表（list）而不是滚动视图（scroll）——滚动视图没有固有高度，
    /// 量它会得到 0，面板就会被算矮、候选被压没。
    private var fitBlocks: [UIView] = []
    private var lastFit: (mode: Mode, width: CGFloat)?
    /// 反馈要落在当前页面的那行小字上（结果页是脚注，初始页是顶部提示行）
    private weak var flashTarget: UILabel?
    /// 系统容器比我们视图高出的那一截（露出来就是顶部那条「色块」）；每次出现只量一次
    private var containerGap: CGFloat = 0
    private var didMeasureContainerGap = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 兜底入口：长按键盘任意处 1.5 秒，呼出本地 Key 面板（共享容器断链时唯一不依赖签名的通路）
        let kbLocalPanelGesture = UILongPressGestureRecognizer(target: self, action: #selector(openLocalKeyPanel))
        kbLocalPanelGesture.minimumPressDuration = 1.5
        kbLocalPanelGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(kbLocalPanelGesture)

        // 面板底色交给系统，不要自己设：这个视图本身就是 UIInputView（.keyboard 样式），
        // 系统会给它画与键盘容器同一套底材。之前用自定义的 KB.bg 盖掉了它，于是我们面板
        // 和键盘顶部露出的那层底衬颜色对不上，看着就像多了一条"灰带"。
        // 不设背景色后两边同源同色，深色模式也跟着系统走。
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        buildTopBar()
        buildContentStack()
        mode = hasFullAccess ? .idle : .gate
#if DEBUG
        // 自检探针：任何落到面板上的点按都记一笔，并报告命中的视图类型。
        // 用来区分「触摸压根没进来」和「进来了但没送到候选行」。
        let probe = UITapGestureRecognizer(target: self, action: #selector(diagProbe(_:)))
        probe.cancelsTouchesInView = false
        view.addGestureRecognizer(probe)
#endif
        render()
    }

#if DEBUG
    @objc private func diagProbe(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        let hit = view.hitTest(p, with: nil)
        JevStore.diag(String(format: "面板点按 (%.0f,%.0f) 命中=%@", p.x, p.y,
                             String(describing: type(of: hit ?? UIView())))
            + " 状态=\(mode)")
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        statusLabel.text = hasFullAccess ? L("Jev · 已连接", "Jev · Connected")
            : L("Jev · 需要完全访问", "Jev · Full Access required")
        render()
        // 回写状态：主 App「开始」页据此显示键盘是否已启用、是否给了完全访问
        JevStore.saveKeyboardStatus(KeyboardStatus(lastSeen: Date(), hasFullAccess: hasFullAccess))
        prewarm()
        // 刚出现时 frame 还没定，等键盘铺开后再量容器间隙
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.coverContainerGap()
        }
    }

    /// 预热生成层连接。实测同一条起草请求，第二次能从 ~1.9 秒降到 ~0.5 秒——
    /// 连接和模型服务都要热身。键盘一出现就用一个不消耗额度的 `GET /models` 把连接建起来，
    /// 结果直接丢掉（失败也无所谓，真分析时该走的路径照走）。
    private func prewarm() {
        guard hasFullAccess else { return }
        let g = KBLocalConfig.resolve().generation
        guard !g.key.isEmpty, !g.base.isEmpty else { return }
        let base = g.base.hasSuffix("/") ? String(g.base.dropLast()) : g.base
        guard let url = URL(string: base + "/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(g.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        view.layer.borderColor = KB.cardBorder.cgColor
        // 重建各状态视图以刷新动态色
        if mode == .idle || mode == .gate { render() }
    }

    // MARK: 顶栏：品牌 + 状态 + 系统键盘切换 + 删除

    private func buildTopBar() {
        let dot = UIView()
        dot.backgroundColor = hasFullAccess ? KB.riskColor(0) : .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel = KB.label(hasFullAccess ? L("Jev · 已连接", "Jev · Connected") : L("Jev · 需要完全访问", "Jev · Full Access required"),
                               font: .systemFont(ofSize: 12, weight: .medium), color: KB.secondaryText)

        let title = UIStackView(arrangedSubviews: [dot, statusLabel])
        title.axis = .horizontal
        title.spacing = 6
        title.alignment = .center

        let globe = KB.button("", icon: "globe")
        globe.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        NSLayoutConstraint.activate([
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 36),
        ])

        let backspace = KB.button("", icon: "delete.left")
        backspace.addTarget(self, action: #selector(deleteBackwardTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            backspace.widthAnchor.constraint(equalToConstant: 44),
            backspace.heightAnchor.constraint(equalToConstant: 36),
        ])

        topBar.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        let hstack = UIStackView(arrangedSubviews: [UIView(), globe, backspace])
        hstack.axis = .horizontal
        hstack.spacing = 8
        topBar.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 36),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hstack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            hstack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
        ])
    }

    private func buildContentStack() {
        contentStack.axis = .vertical
        contentStack.spacing = 6
        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heightConstraint,
        ])
    }

    /// 面板高度按内容实测定，而不是把 320 写死。
    ///
    /// 写死一个高度 + UIStackView 默认的 .fill：多余的垂直空间会被平分下去，卡片被拉伸出
    /// 一大片空白（卡片底色和键盘底色几乎一样白，看着就是"空白太多"），该占空间的候选滚动区
    /// 反被挤成一条（"就只有一个东西"）。这里把各块在真实宽度下的高度加起来定高，190 起、470 封顶，
    /// 超出的部分才交给滚动。
    private func refit() {
        let avail = view.bounds.width - 24
        guard avail > 60, !fitBlocks.isEmpty else { return }
        var height: CGFloat = 6 + 36 + 6 + 8      // 上边距 + 顶栏 + 间距 + 下边距
        for (i, block) in fitBlocks.enumerated() {
            height += block.systemLayoutSizeFitting(
                CGSize(width: avail, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if i < fitBlocks.count - 1 { height += 6 }
        }
        heightConstraint.constant = min(max(height, Self.minPanelHeight), maxPanelHeight) + containerGap
    }

    /// 面板高度下限。**不能低于系统键盘的最小高度**：实测请求 190pt 时，系统按自己的最小值
    /// （约 204pt）给键盘区域，我们的视图只有 190 又被贴底，上方那 14pt 就露出系统的圆角底衬
    /// ——看起来就是键盘顶上多了一条灰带（结果态高度够大，所以不带这个问题）。
    private static let minPanelHeight: CGFloat = 210

    /// 键盘面板上方那条"灰带"的成因排查（结论：不是缝隙，量出来容器与视图**等高**）。
    /// 这段保留作兜底：万一某个 App/机型上容器真的比视图高，就把视图补到容器高度、用背景盖住。
    /// 关键点：**必须等 frame 铺开后再量**——刚出现时 frame 是整屏尺寸（390x844），
    /// 拿它算会得到 0 并误标"已量过"，于是永远不再量（上一版就是这么失效的）。
    private func coverContainerGap() {
        guard !didMeasureContainerGap, let container = view.superview else { return }
        let containerHeight = container.bounds.height
        let viewHeight = view.bounds.height
        guard containerHeight > 0, viewHeight > 0,
              containerHeight < 600, viewHeight < 600 else { return }  // 还没铺开，下次再看
        didMeasureContainerGap = true
        let gap = containerHeight - viewHeight
        guard gap > 1, gap <= 60 else { return }
        containerGap = gap
        lastFit = nil
        refit()
#if DEBUG
        JevStore.diag(String(format: "补容器间隙 %.0fpt（容器 %.0f / 视图 %.0f）",
                             gap, containerHeight, viewHeight))
#endif
    }

    /// 面板上限跟着屏幕走：小屏（SE 667pt）上写死 470 会盖掉大半个屏幕，
    /// 大屏（Pro Max 932pt）上又不该浪费空间。取可用高度的 45%，夹在 [220, 470] 之间。
    /// 用窗口场景的坐标系而不是 UIScreen.bounds——后者恒为竖屏尺寸，横屏时会算多。
    private var maxPanelHeight: CGFloat {
        let scene = view.window?.windowScene
        let available = scene?.coordinateSpace.bounds.height ?? UIScreen.main.bounds.height
        return min(470, max(220, available * 0.45))
    }

#if DEBUG
    private func frameText(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        coverContainerGap()               // 铺开后如果容器比视图高，就补高盖住（通常量到的是等高）
        let width = view.bounds.width
        guard width > 0, lastFit == nil || lastFit!.mode != mode || lastFit!.width != width else { return }
        lastFit = (mode, width)
        refit()
#if DEBUG
        // 顶部那条「色块」的取证（1）：我们视图与直接父视图的几何关系
        let supFrame = view.superview.map { frameText($0.frame) } ?? "nil"
        let supBounds = view.superview.map { frameText($0.bounds) } ?? "nil"
        JevStore.diag("几何 view=\(frameText(view.frame)) 父frame=\(supFrame) 父bounds=\(supBounds) 兄弟数=\(view.superview?.subviews.count ?? -1)")

        // 取证（2）：等键盘真正铺开后再往上数三层容器——iOS 26 的键盘容器自己画圆角底衬，
        // 得知道那一层是什么类、多大、什么颜色，才能判断那条带子是它的还是我们的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            var node: UIView? = self.view
            for _ in 0..<4 {
                guard let cur = node else { break }
                let bg = cur.backgroundColor.map { "\($0)" } ?? "nil"
                parts.append("\(type(of: cur)) \(frameText(cur.frame)) bg=\(bg)")
                node = cur.superview
            }
            JevStore.diag("容器链 " + parts.joined(separator: " | "))
        }
#endif
    }

    @objc private func switchKeyboard() { advanceToNextInputMode() }

    @objc private func deleteBackwardTapped() {
        textDocumentProxy.deleteBackward()
    }

#if DEBUG
    /// 自检入口：把面板直接切到某个状态渲染出来。
    /// 键盘本体不走这条路径；这是给独立预览壳工程用的——键盘扩展没法用脚本唤起，
    /// 靠它才能在模拟器上按不同机型尺寸看布局（见 /tmp 的 PanelPreview 壳）。
    func previewPanel(_ kind: String, analysis: Analysis? = nil, errorText: String = "") {
        self.analysis = analysis
        self.errorText = errorText
        switch kind {
        case "gate": mode = .gate
        case "tones": mode = .tones
        case "loading": mode = .loading
        case "result": mode = .result
        case "error": mode = .error
        default: mode = .idle
        }
        render()
    }
#endif

    // MARK: 状态渲染

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fitBlocks = []
        lastFit = nil
        switch mode {
        case .gate: contentStack.addArrangedSubview(gateView())
        case .idle: contentStack.addArrangedSubview(idleView())
        case .tones: contentStack.addArrangedSubview(tonesView())
        case .loading: contentStack.addArrangedSubview(loadingView())
        case .result: contentStack.addArrangedSubview(resultView())
        case .error: contentStack.addArrangedSubview(errorView())
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        render()
    }

    // MARK: 门禁视图（没有完全访问时）

    private func gateView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("需要「允许完全访问」", "Full Access required"), font: .systemFont(ofSize: 16, weight: .bold),
                             color: .systemRed)
        let steps = KB.label(
            L("Jev 键盘要联网调用模型、读取剪贴板，这两项都要求完全访问：\n\n① 打开系统「设置」→「通用」→「键盘」→「键盘」\n② 点「添加新键盘」→ 选「Jev 键盘」\n③ 点「Jev 键盘」→ 打开「允许完全访问」\n\n完全访问意味着键盘能传输按键与剪贴板内容——本项目开源、只用你自己填的 API Key，不用时可以在同页一键移除。", "Jev needs Full Access to call the model and read the clipboard:\n\n① Open Settings → General → Keyboard → Keyboards\n② Tap Add New Keyboard → Jev Keyboard\n③ Select Jev Keyboard → turn on Full Access\n\nFull Access lets the keyboard transmit keystrokes and clipboard content. The project is open source and uses only the API key you provide; you can remove it anytime."),
            font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let vstack = UIStackView(arrangedSubviews: [title, steps])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 待机视图

    private func idleView() -> UIView {
        let cfg = KBLocalConfig.resolve()

        let guide = KB.label(
            L("长按对方消息 → 复制，再点下面的按钮", "Long-press the message → Copy, then tap a button below"),
            font: .systemFont(ofSize: 12), color: KB.secondaryText)

        let clipBtn = KB.button(L("分析剪贴板", "Analyze Clipboard"), icon: "doc.on.clipboard", primary: true,
                                font: .systemFont(ofSize: 14, weight: .semibold))
        clipBtn.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)

        let inputBtn = KB.button(L("AI 分析输入框文字", "Analyze Input"), icon: "text.cursor",
                                 font: .systemFont(ofSize: 14, weight: .semibold))
        inputBtn.addTarget(self, action: #selector(analyzeInputField), for: .touchUpInside)

        // 两个分析入口并排：左边读剪贴板（主路径，主色），右边读当前输入框
        let btnRow = UIStackView(arrangedSubviews: [clipBtn, inputBtn])
        btnRow.axis = .horizontal
        btnRow.spacing = 8
        btnRow.distribution = .fillEqually
        btnRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // 话术：点进去直接在键盘上选（写回共享配置，App 的「话术」页看到的是同一份）
        let tonesBtn = KB.button(
            cfg.activeSlots.isEmpty
                ? L("话术：都没选（点这里选）", "Tones: none selected")
                : L("话术：", "Tones: ") + cfg.activeSlots.map { localizedToneName($0, language: language) }.joined(separator: " · "),
            icon: "theatermasks")
        tonesBtn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        tonesBtn.addTarget(self, action: #selector(openTonePicker), for: .touchUpInside)

        // 待机页**不放**发送键：这一页还没有候选，没有可发的东西；而输入框一旦有字，
        // 宿主 App 自己的发送按钮就出来了，
        // 键盘下方再挂一个只是添乱。发送键只在结果页——点完候选、手还在面板上时用。
        let vstack = UIStackView(arrangedSubviews: [guide, btnRow, tonesBtn])
        vstack.axis = .vertical
        vstack.spacing = 8
        if JevDraft(cfg: cfg).isConfigured {
            // 配置完整时不占行
        } else {
            // 免费 Apple ID 拿不到 App Group（苹果的能力限制，任何重签工具都改不了），
            // 键盘本地这份配置才是免费账号下唯一走得通的通路——所以入口必须显眼，
            // 不能藏在「长按 1.5 秒」这种没人知道的手势里。
            let fixBtn = KB.button(L("🔑 在键盘里填 API Key", "🔑 Enter API key here"),
                                   icon: "key.fill", primary: true,
                                   font: .systemFont(ofSize: 14, weight: .semibold))
            fixBtn.heightAnchor.constraint(equalToConstant: 38).isActive = true
            fixBtn.addTarget(self, action: #selector(openLocalKeyPanel), for: .touchUpInside)
            vstack.addArrangedSubview(fixBtn)

            let why = JevStore.groupContainerAvailable
                ? L("⚠️ 还没配置生成层：不用打开 App——点上面这个按钮，接口地址 / API Key / 模型名填在键盘里就行（也可以先在 App 的「模型」页点「复制配置串（给键盘）」，再回来点「从 App 粘贴配置」）。",
                    "⚠️ Not configured: no need to open the app — tap the button above to fill base URL / API key / model right here (or copy the config string from the app's Models page and paste it here).")
                : L("⚠️ App Group 共享容器不可用：这是免费 Apple ID 的固有限制（苹果不向个人团队发放 App Group 能力，换任何重签工具都一样），所以键盘读不到 App 里填的 Key。点上面这个按钮在键盘里填一份即可——不依赖共享容器，填完立刻能用。想让它俩自动共享，需要付费开发者账号（$99/年）或 iOS ≤17.0 的 TrollStore。",
                    "⚠️ App Group shared container unavailable: this is an inherent limit of free Apple IDs (Apple does not grant App Groups to personal teams, and no signing tool can change that), so the keyboard cannot read the key saved in the app. Tap the button above and fill the key right here — no shared container needed. For automatic sharing you need a paid developer account or TrollStore on iOS ≤17.0.")
            let warn = KB.label(why, font: .systemFont(ofSize: 12),
                                color: JevStore.groupContainerAvailable ? .systemOrange : .systemRed, lines: 0)
            vstack.addArrangedSubview(warn)
        }
        fitBlocks = [vstack]
        return vstack
    }

    // MARK: 话术选择视图（直接在键盘上配）

    @objc private func openTonePicker() { setMode(.tones) }

    /// 话术选择：内置 + 自定义全列出来，点一下选中/取消，最多 3 个槽。
    /// 每次从共享配置重新读（App 那边改过也能立刻看到），选中即落盘，下一次分析就生效。
    private func tonesView() -> UIView {
        let cfg = KBLocalConfig.resolve()
        let names = orderedToneNames(custom: cfg.customTones)
        let active = cfg.activeSlots

        let title = KB.label(L("选话术（最多 \(MAX_SLOTS) 个 · 每个每次出 2 条）", "Choose tones (up to \(MAX_SLOTS) · 2 suggestions each)"),
                             font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0)
        var blocks: [UIView] = [title]

        // 每行 3 个等宽格子：话术名长短不一，等宽比按内容排更好点、也更整齐
        var row: [UIButton] = []
        for name in names {
            let btn = KB.button(localizedToneName(name, language: language), primary: active.contains(name),
                                font: .systemFont(ofSize: 13, weight: .medium))
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            btn.accessibilityIdentifier = name
            btn.addTarget(self, action: #selector(toneChipTapped(_:)), for: .touchUpInside)
            row.append(btn)
            if row.count == 3 {
                blocks.append(gridRow(row))
                row = []
            }
        }
        if !row.isEmpty {
            // 补齐到 3 个：不加空位的话，最后一行的单个话术会被 .fillEqually 拉成整行宽
            var cells: [UIView] = row
            while cells.count < 3 { cells.append(UIView()) }
            blocks.append(gridRow(cells))
        }

        let done = KB.button(L("好了", "Done"), icon: "checkmark", primary: true)
        done.heightAnchor.constraint(equalToConstant: 36).isActive = true
        done.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        blocks.append(done)

        let outer = UIStackView(arrangedSubviews: blocks)
        outer.axis = .vertical
        outer.spacing = 6
        fitBlocks = blocks
        return outer
    }

    private func gridRow(_ cells: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: cells)
        s.axis = .horizontal
        s.spacing = 6
        s.distribution = .fillEqually
        return s
    }

    @objc private func toneChipTapped(_ sender: UIButton) {
        guard let name = sender.accessibilityIdentifier else { return }
        var cfg = KBLocalConfig.resolve()
        var slots = cfg.slots
        while slots.count < MAX_SLOTS { slots.append(NONE_LABEL) }
        if let i = slots.firstIndex(of: name) {
            slots[i] = NONE_LABEL                      // 再点一下 = 取消
        } else if let free = slots.firstIndex(where: { $0.isEmpty || $0 == NONE_LABEL }) {
            slots[free] = name                         // 填进第一个空槽
        } else {
            slots[MAX_SLOTS - 1] = name                // 槽满了就顶掉最后一个
        }
        cfg.slots = Array(slots.prefix(MAX_SLOTS))
        JevStore.saveConfig(cfg)                       // 立刻落盘：下一次分析就用新槽位
        render()                                       // 重画刷新高亮
    }

    // MARK: 加载视图

    private func loadingView() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stageLabel = KB.label(L("分析中…", "Analyzing…"), font: .systemFont(ofSize: 14), color: KB.secondaryText)
        let hstack = UIStackView(arrangedSubviews: [spinner, stageLabel])
        hstack.axis = .horizontal
        hstack.spacing = 10
        hstack.alignment = .center
        let card = KB.cardView()
        card.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            hstack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 96),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 结果视图

    private func resultView() -> UIView {
        guard let a = analysis else { return UIView() }
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 5

        // 判断头
        let header = KB.cardView()
        var headerItems: [UIView] = []
        if let jr = a.judge {
            // 风险等级文案跟徽章同一行——它单独占一行太浪费高度（键盘面板寸土寸金）
            let riskText = KB.label(localizedRiskLabel(jr.risk, language: language), font: .systemFont(ofSize: 12),
                                    color: KB.riskColor(jr.risk), lines: 1)
            riskText.setContentHuggingPriority(.required, for: .horizontal)
            let chipRow = UIStackView(arrangedSubviews: [
                KB.badge(localizedIntent(jr.intent, language: language), color: KB.brand),
                KB.badge(L(String(format: "风险 %.0f/9", jr.risk), String(format: "Risk %.0f/9", jr.risk)), color: KB.riskColor(jr.risk)),
                riskText,
                UIView(),   // 占位：吃掉余量，徽章和文案各自按内容 hug
            ])
            chipRow.axis = .horizontal
            chipRow.spacing = 8
            headerItems.append(chipRow)
            if !jr.actions.isEmpty {
                headerItems.append(KB.label(L("建议：", "Next: ") + localizedActions(jr.actions, language: language).joined(separator: " · "),
                                            font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0))
            }
        } else {
            headerItems.append(KB.label(L("未配置判断层，直接生成（可在 App 里开启）", "Judge not configured; drafting directly (enable it in the app)"),
                                        font: .systemFont(ofSize: 12), color: KB.secondaryText))
        }
        let quoted = KB.label("「" + (a.message.count > 40 ? String(a.message.prefix(40)) + "…" : a.message) + "」",
                              font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 1)
        headerItems.append(quoted)
        let hstack = UIStackView(arrangedSubviews: headerItems)
        hstack.axis = .vertical
        hstack.spacing = 4
        hstack.isLayoutMarginsRelativeArrangement = true
        hstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        header.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: header.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        outer.addArrangedSubview(header)

        // 时间脚注（先建好：插入/发送的反馈要临时改它）
        let footer = KB.label(a.rankingPending
                                ? L("候选已出 · 排序中…（现在就能点）", "Suggestions ready · ranking… (you can tap now)")
                                : L(String(format: "%.1f 秒 · 点候选插入，点「发送」发出", a.elapsed), String(format: "%.1f s · tap a suggestion to insert, then Send", a.elapsed)),
                              font: .systemFont(ofSize: 10), color: KB.secondaryText)
        flashTarget = footer

        // 候选列表（可滚动）。真没有候选时也要说一句话，别留给用户一片空白。
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        if a.candidates.isEmpty {
            list.addArrangedSubview(KB.label(L("这次没出候选，点「换一批」再试一次", "No suggestions this time. Tap Regenerate to try again."),
                                             font: .systemFont(ofSize: 13),
                                             color: KB.secondaryText, lines: 0))
        }
        for c in a.candidates {
            let row = CandidateRow(candidate: c)
            row.onInsert = { [weak self] candidate in
                guard let self else { return }
#if DEBUG
                JevStore.diag("准备插入：话术=\(candidate.tone) 字数=\(candidate.text.count)")
#endif
                self.textDocumentProxy.insertText(candidate.text)
#if DEBUG
                let ctx = self.textDocumentProxy.documentContextBeforeInput ?? "<拿不到>"
                JevStore.diag("插入后输入框尾部=「\(ctx.suffix(24))」")
#endif
                self.flashFooter(self.L("已插入 · 点「发送」发出", "Inserted · tap Send to submit"), color: KB.riskColor(0))
            }
            list.addArrangedSubview(row)
        }
        for n in a.notices.prefix(2) {
            list.addArrangedSubview(KB.label("· " + n, font: .systemFont(ofSize: 11),
                                             color: .systemOrange, lines: 0))
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        // 别让滚动视图拖延把触摸交给候选行——延迟投递正是"点了没反应"的常见来源
        scroll.delaysContentTouches = false
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        outer.addArrangedSubview(scroll)

        // 底部操作：发送挪到右下角，左边留给换一批/返回
        let send = KB.button(L("发送", "Send"), icon: "paperplane.fill", primary: true)
        send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        send.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let regen = KB.button(L("换一批", "Regenerate"), icon: "arrow.clockwise")
        regen.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [regen, close, UIView(), send])
        actions.axis = .horizontal
        actions.spacing = 8
        outer.addArrangedSubview(actions)
        outer.addArrangedSubview(footer)

        // 只让候选区伸缩：卡片/按钮都按内容 hug，否则会被多余的垂直空间拉出空白。
        header.setContentHuggingPriority(.required, for: .vertical)
        actions.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        fitBlocks = [header, list, actions, footer]
        return outer
    }

    /// 即时反馈：目标那行小字短暂变色改字。用户要一眼能确认「点到了 / 插进去了 / 发出去了」。
    private func flashFooter(_ text: String, color: UIColor) {
        guard let target = flashTarget else { return }
        let base = target.text
        target.textColor = color
        target.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak target] in
            target?.textColor = KB.secondaryText
            target?.text = base
        }
    }

    /// 发送。键盘扩展**点不了宿主 App 的发送按钮**（iOS 没这个 API），唯一能用的杠杆是插一个换行：
    /// 对「把回车当发送」的聊天 App 有效（输入框是文本视图、在 shouldChangeTextInRange 里拦换行的那些），
    /// 对单行输入框无效。所以发完回读输入框，按实际结果如实反馈，不假装成功。
    @objc private func sendMessage() {
        guard hasFullAccess else { setMode(.gate); return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText("\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let after = self.textDocumentProxy.documentContextBeforeInput ?? ""
            if before.isEmpty && after.isEmpty {
                self.flashFooter(self.L("输入框是空的：先点一条候选", "The input is empty: tap a suggestion first"), color: .systemOrange)
            } else if after.isEmpty {
                self.flashFooter(self.L("已发送 ✓", "Sent ✓"), color: KB.riskColor(0))
            } else {
                self.flashFooter(self.L("这个 App 不吃键盘换行，请点它的发送按钮", "This app does not send on Return; tap its Send button"), color: .systemOrange)
            }
        }
    }

    // MARK: 错误视图

    private func errorView() -> UIView {
        let card = KB.cardView()
        let title = KB.label(L("出错了", "Something went wrong"), font: .systemFont(ofSize: 15, weight: .bold), color: .systemRed)
        let body = KB.label(errorText, font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let retry = KB.button(L("重试", "Retry"), icon: "arrow.clockwise")
        retry.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button(L("返回", "Back"), icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let btns = UIStackView(arrangedSubviews: [retry, close])
        btns.axis = .horizontal
        btns.spacing = 8
        // 未配置时给一条直达键盘内填 Key 的路：错误页不该是死胡同。
        var rows: [UIView] = [title, body]
        if !JevDraft(cfg: KBLocalConfig.resolve()).isConfigured {
            let fix = KB.button(L("🔑 在键盘里填 API Key", "🔑 Enter API key here"),
                                icon: "key.fill", primary: true,
                                font: .systemFont(ofSize: 14, weight: .semibold))
            fix.heightAnchor.constraint(equalToConstant: 36).isActive = true
            fix.addTarget(self, action: #selector(openLocalKeyPanel), for: .touchUpInside)
            rows.append(fix)
        }
        rows.append(btns)
        let vstack = UIStackView(arrangedSubviews: rows)
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 动作

    @objc private func analyzeClipboard() {
        lastSource = .clipboard
        guard hasFullAccess else { setMode(.gate); return }
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = L("剪贴板是空的。先在聊天里长按要回的消息 →「复制」，再回来点分析。", "The clipboard is empty. Long-press a message in your chat, copy it, then tap Analyze.")
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func analyzeInputField() {
        lastSource = .inputField
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let text = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = L("输入框里没有文字。这个按钮分析的是当前输入框里已输入的内容（比如你打了一半拿不准的话）。", "The input is empty. This button analyzes text already typed in the field.")
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func regenerate() { run(message: lastMessage) }
    @objc private func backToIdle() { setMode(.idle) }

    private func run(message: String) {
        lastMessage = message
        setMode(.loading)
        stageLabel.text = L("判断中…", "Judging…")
        let pipeline = JevPipeline(cfg: KBLocalConfig.resolve())

        Task { @MainActor [weak self] in
            let analysis = await pipeline.analyze(
                message: message, context: nil,
                onStage: { [weak self] stage in
                    Task { @MainActor in
                        switch stage {
                        case .judging: self?.stageLabel.text = self?.L("判断中…", "Judging…")
                        case .drafting(let done, let total):
                            self?.stageLabel.text = self?.L("生成中 \(done)/\(total)…", "Drafting \(done)/\(total)…")
                        case .ranking: self?.stageLabel.text = self?.L("排序中…", "Ranking…")
                        case .done: self?.stageLabel.text = self?.L("完成", "Done")
                        }
                    }
                },
                onPartial: { [weak self] partial in
                    // 第一条话术的候选一到就先出面板，不等其余话术、更不等排序。
                    // 用消息文本挡一下，别让上一轮的迟到结果盖掉新一轮。
                    Task { @MainActor in
                        guard let self, self.lastMessage == partial.message else { return }
                        self.analysis = partial
                        self.setMode(.result)
                    }
                })
            guard let self else { return }
            self.analysis = analysis
            if let fatal = analysis.fatalError {
                self.errorText = fatal
                self.setMode(.error)
            } else {
                self.setMode(.result)
            }
        }
    }
}


// MARK: - 本地 Key 面板（长按键盘 1.5 秒呼出）

/// 面板是独立类，看不到键盘控制器私有的 L()，给一个文件级替身（语言跟随应用设置）。
private func KBL(_ zh: String, _ en: String) -> String {
    JevStore.loadLanguage() == .english ? en : zh
}


extension KeyboardViewController {
    @objc func openLocalKeyPanel() {
        KBLocalKeyPanel.show(in: self)
    }
}

final class KBLocalKeyPanel: UIView {
    static func show(in vc: UIViewController) {
        guard !vc.view.subviews.contains(where: { $0 is KBLocalKeyPanel }) else { return }
        let panel = KBLocalKeyPanel(frame: vc.view.bounds)
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(panel)
    }

    private let baseField = UITextField()
    private let keyField = UITextField()
    private let modelField = UITextField()
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        buildPanel()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func buildPanel() {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.14, alpha: 1)
        card.layer.cornerRadius = 14
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor, constant: -24),
        ])

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 9
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        let title = UILabel()
        title.text = KBL("键盘内直接填 Key", "Fill the key right here")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.numberOfLines = 0

        let shared = JevStore.loadConfig()
        let note = UILabel()
        note.font = .systemFont(ofSize: 11)
        note.textColor = UIColor(white: 0.75, alpha: 1)
        note.numberOfLines = 0
        let sharedState = shared.genKey.isEmpty
            ? KBL("共享层没有 Key（免费 Apple ID 用不了 App Group，属于苹果限制）。下面填一份，或先在 App「模型」页点「复制配置串（给键盘）」再点下面的「从 App 粘贴配置」。",
                  "No key in the shared layer (free Apple IDs cannot use App Groups — an Apple restriction). Fill it below, or copy the config string from the app and paste it here.")
            : KBL("共享层 Key 已就绪；这里填的是兜底，共享层优先。", "Shared key present; this is only a fallback.")
        note.text = sharedState

        let d = KBLocalConfig.d
        baseField.text = d.string(forKey: KBLocalConfig.kBase)
        if (baseField.text ?? "").isEmpty { baseField.text = "https://api.deepseek.com" }
        baseField.placeholder = KBL("接口地址（如 https://api.deepseek.com）", "Base URL")
        style(baseField)

        keyField.isSecureTextEntry = true
        keyField.text = d.string(forKey: KBLocalConfig.kKey)
        keyField.placeholder = KBL("API Key（sk-…）", "API Key")
        style(keyField)

        modelField.text = d.string(forKey: KBLocalConfig.kModel)
        if (modelField.text ?? "").isEmpty { modelField.text = "deepseek-chat" }
        modelField.placeholder = KBL("模型名（如 deepseek-chat）", "Model name")
        style(modelField)

        status.font = .systemFont(ofSize: 11)
        status.textColor = UIColor(red: 0.5, green: 0.85, blue: 0.5, alpha: 1)
        status.numberOfLines = 0

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        let save = UIButton(type: .system)
        save.setTitle(KBL("保存", "Save"), for: .normal)
        save.setTitleColor(.white, for: .normal)
        save.backgroundColor = UIColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1)
        save.layer.cornerRadius = 8
        save.heightAnchor.constraint(equalToConstant: 34).isActive = true
        save.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setTitle(KBL("关闭", "Close"), for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.backgroundColor = UIColor(white: 0.3, alpha: 1)
        close.layer.cornerRadius = 8
        close.heightAnchor.constraint(equalToConstant: 34).isActive = true
        close.addAction(UIAction { [weak self] _ in self?.removeFromSuperview() }, for: .touchUpInside)
        let pasteBtn = UIButton(type: .system)
        pasteBtn.setTitle(KBL("从 App 粘贴配置", "Paste from app"), for: .normal)
        pasteBtn.setTitleColor(.white, for: .normal)
        pasteBtn.titleLabel?.font = .systemFont(ofSize: 13)
        pasteBtn.backgroundColor = UIColor(white: 0.32, alpha: 1)
        pasteBtn.layer.cornerRadius = 8
        pasteBtn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        pasteBtn.addAction(UIAction { [weak self] _ in self?.pasteFromClipboard() }, for: .touchUpInside)
        row.addArrangedSubview(save)
        row.addArrangedSubview(pasteBtn)
        row.addArrangedSubview(close)

        for v in [title, note, baseField, keyField, modelField, status, row] as [UIView] {
            stack.addArrangedSubview(v)
        }
    }

    private func style(_ f: UITextField) {
        f.backgroundColor = UIColor(white: 0.24, alpha: 1)
        f.textColor = .white
        f.font = .systemFont(ofSize: 12)
        f.layer.cornerRadius = 8
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    /// 从 App 复制来的配置串里恢复三项配置。格式：JEV1:<base64(JSON{base,key,model})>
    /// 完全绕开 App Group —— 剪贴板是免费账号下唯一的跨进程通道。
    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("JEV1:") else {
            status.text = KBL("剪贴板里没有配置串。先在 App 的「模型」页点「复制配置串（给键盘）」。",
                              "No config string in the clipboard. Copy it from the app's Models page first.")
            return
        }
        guard let data = Data(base64Encoded: String(raw.dropFirst(5))),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            status.text = KBL("配置串解析失败，请重新复制一次。", "Could not parse the config string; please copy it again.")
            return
        }
        if let b = obj["base"], !b.isEmpty { baseField.text = b }
        if let k = obj["key"], !k.isEmpty { keyField.text = k }
        if let m = obj["model"], !m.isEmpty { modelField.text = m }
        status.text = KBL("已从配置串填入 ✓ 点「保存」生效", "Filled from the config string ✓ tap Save")
    }

    private func save() {
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status.text = KBL("Key 还是空的", "Key is empty")
            return
        }
        let d = KBLocalConfig.d
        d.set(key, forKey: KBLocalConfig.kKey)
        let base = (baseField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { d.set(base, forKey: KBLocalConfig.kBase) }
        let model = (modelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { d.set(model, forKey: KBLocalConfig.kModel) }
        status.text = KBL("已保存 ✓ 下一次分析生效", "Saved ✓ takes effect on next analysis")
    }
}
