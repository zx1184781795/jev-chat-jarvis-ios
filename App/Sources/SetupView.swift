import SwiftUI
import Combine

/// 开始页：键盘装没装、完全访问给没给、共享配置通不通，一眼看清。
struct SetupView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var kbStatus: KeyboardStatus?
    @State private var groupOK = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                languageSection
                statusSection
                howSection
                privacySection
            }
            .navigationTitle("Jev Jarvis")
            .onAppear { refresh() }
            .onReceive(timer) { _ in refresh() }
        }
    }

    private func refresh() {
        kbStatus = JevStore.loadKeyboardStatus()
        groupOK = JevStore.groupWritable
    }

    private var languageSection: some View {
        Section(jevLocalized(store.language, zh: "语言", en: "Language")) {
            Picker(jevLocalized(store.language, zh: "界面语言", en: "Interface language"), selection: $store.language) {
                ForEach(JevLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
    }

    // MARK: 状态卡

    private var statusSection: some View {
        Section {
            row(icon: "keyboard", title: jevLocalized(store.language, zh: "键盘已启用", en: "Keyboard enabled"),
                ok: kbStatus != nil,
                detail: kbStatus.map {
                    jevLocalized(store.language,
                                 zh: "最近使用：\(timeAgo($0.lastSeen))。若你已移除键盘，这里不会自动变灰——重新添加后在输入框唤起一次即可刷新",
                                 en: "Last used: \(timeAgo($0.lastSeen)). If you removed the keyboard this won't turn gray by itself — re-add it and open it once in any text field to refresh")
                } ?? jevLocalized(store.language, zh: "还没检测到键盘被唤起过（在任意输入框里切换到 Jev 键盘即可）", en: "The keyboard has not been opened yet. Switch to Jev in any text field."))

            row(icon: "lock.open", title: jevLocalized(store.language, zh: "允许完全访问", en: "Full Access"),
                ok: kbStatus?.hasFullAccess == true,
                detail: kbStatus == nil
                    ? jevLocalized(store.language,
                                   zh: "还没有键盘状态：先在任意输入框切到 Jev 键盘唤起一次，这里才会显示真实开关状态",
                                   en: "No keyboard state yet. Switch to the Jev keyboard in any text field once — this row then shows the real switch state.")
                    : (kbStatus?.hasFullAccess == true
                        ? jevLocalized(store.language, zh: "已开启：键盘可以联网、读剪贴板", en: "On: the keyboard can use the network and clipboard")
                        : jevLocalized(store.language, zh: "未开启：键盘无法联网和读剪贴板，也不会出候选", en: "Off: the keyboard cannot use the network or clipboard")))

            row(icon: "externaldrive.connected.to.line.below", title: jevLocalized(store.language, zh: "App Group 共享", en: "App Group sharing"),
                ok: groupOK, detail: groupOK
                    ? jevLocalized(store.language, zh: "配置可以同步到键盘", en: "Configuration syncs to the keyboard")
                    : jevLocalized(store.language, zh: "免费 Apple ID 用不了 App Group（苹果的能力限制，任何重签工具都改不了），键盘读不到这里填的 Key。不影响使用：上面的配置请点下面「复制配置串（给键盘）」，再在键盘面板点「从 App 粘贴配置」；也可以直接在键盘上点「🔑 在键盘里填 API Key」填一份。", en: "Free Apple IDs cannot use App Groups (an Apple capability limit no signing tool can change), so the keyboard cannot read the key entered here. Not a blocker: tap Copy config for keyboard below, then Paste from app in the keyboard panel — or fill the key directly with the 🔑 button in the keyboard."))
        } header: {
            Text(jevLocalized(store.language, zh: "状态", en: "Status"))
        } footer: {
            Text(jevLocalized(store.language, zh: "键盘每次被唤起时会回写状态，这里每 2 秒刷新。共享通道「App Group 共享」只对付费开发者账号（$99/年）或 iOS ≤17.0 的 TrollStore 可用；免费账号走键盘内配置，功能完全一样，只是要各填一次。", en: "The keyboard writes its status when opened. This view refreshes every 2 seconds. The App Group shared channel requires a paid developer account ($99/yr) or TrollStore on iOS ≤17.0; on a free account use the in-keyboard config — same functionality, just entered twice."))
        }
    }

    private func row(icon: String, title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(ok ? Color.green : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 步骤

    private var howSection: some View {
        Section(jevLocalized(store.language, zh: "三步启用", en: "Set up in three steps")) {
            step(1, jevLocalized(store.language, zh: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Jev 键盘", en: "Settings → General → Keyboard → Keyboards → Add New Keyboard → Jev Keyboard"))
            step(2, jevLocalized(store.language, zh: "回到「键盘」列表，点 Jev 键盘 → 打开「允许完全访问」", en: "Return to Keyboards, select Jev Keyboard, and turn on Full Access"))
            step(3, jevLocalized(store.language, zh: "去「模型」页填一个 API Key（如智谱 glm-4-flash）；免费账号键盘读不到 App 的配置，所以再在键盘上点「🔑 在键盘里填 API Key」填同一套（或点这里的「复制配置串（给键盘）」→ 键盘面板「从 App 粘贴配置」）。然后在聊天 App 里：长按消息 → 复制 → 点「分析剪贴板」", en: "Add an API key on Models (e.g. Zhipu glm-4-flash), then in any chat app long-press a message, copy it, and tap Analyze Clipboard"))
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(n))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    // MARK: 隐私

    private var privacySection: some View {
        Section(jevLocalized(store.language, zh: "隐私边界", en: "Privacy")) {
            Label(jevLocalized(store.language, zh: "聊天内容只发给你自己配置的模型接口，无自建服务器、不落盘、不进日志", en: "Chat content is sent only to the model endpoint you configure. No server, storage, or logs."), systemImage: "hand.raised")
            Label(jevLocalized(store.language, zh: "Key 存在本机 App Group 私有容器，仅 App 与键盘可读", en: "The key stays in a private App Group container readable only by the app and keyboard."), systemImage: "key")
            Label(jevLocalized(store.language, zh: "候选只「插入」输入框，发送永远由你手动完成", en: "Suggestions are only inserted into the field. You always send manually."), systemImage: "square.and.arrow.down.on.square")
            Label(jevLocalized(store.language, zh: "键盘不监听、不上传按键内容；完全访问可随时在系统设置里关闭或移除键盘", en: "The keyboard does not monitor or upload keystrokes. Full Access can be disabled anytime."), systemImage: "shield")
        }
        .font(.subheadline)
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if store.language == .english {
            if s < 60 { return "\(Int(s)) sec ago" }
            if s < 3600 { return "\(Int(s / 60)) min ago" }
            return "\(Int(s / 3600)) hr ago"
        }
        if s < 60 { return "\(Int(s)) 秒前" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        return "\(Int(s / 3600)) 小时前"
    }
}
