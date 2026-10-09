import SwiftUI

/// 话术页：3 个槽位选语气 + 自定义话术。与 macOS 版悬浮窗下拉同语义。
struct TonesView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                junshiSection
                slotsSection
                customSection
                previewSection
            }
            .navigationTitle(jevLocalized(store.language, zh: "话术", en: "Tones"))
            .sheet(isPresented: $showAdd) { AddToneView() }
        }
    }

    /// 狗头军师推演开关。开了以后生成由一个「先推演利弊、再定三档口径」的环节接管，
    /// 下面的话术槽就不参与生成了（配置仍保留，关掉即恢复）。
    private var junshiSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.config.junshi },
                set: { store.config.junshiEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(jevLocalized(store.language, zh: "狗头军师推演", en: "Strategist weighing"))
                    Text(jevLocalized(store.language, zh: "先推演局面与利弊，再按「稳健 / 会撩 / 强势」三档出候选",
                                      en: "Weigh the situation first, then draft in three tiers (Steady / Playful / Bold)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(jevLocalized(store.language, zh: "生成方式", en: "Generation mode"))
        } footer: {
            Text(jevLocalized(store.language, zh: "开启后链路：判断 → 军师推演（局面 / 利弊 / 首选 / 风险）→ 三档候选 → 排序。代价是多一次模型调用、多几秒。关掉则完全按下面的话术槽生成。",
                              en: "On: judge → weigh (situation / trade-offs / advice / risks) → three-tier suggestions → rank. Costs one extra model call and a few seconds. Off: the tone slots below are used."))
        }
    }

    private var slotOptions: [String] {
        [NONE_LABEL] + store.toneCatalog.keys.sorted { lhs, rhs in
            toneOrder(lhs) < toneOrder(rhs)
        }
    }

    /// 内置话术按 styles.py 的顺序展示，自定义排后面
    private func toneOrder(_ name: String) -> Int {
        BUILTIN_TONE_ORDER.firstIndex(of: name) ?? (BUILTIN_TONE_ORDER.count + 1)
    }

    private var slotsSection: some View {
        Section {
            ForEach(0..<MAX_SLOTS, id: \.self) { i in
                Picker(jevLocalized(store.language, zh: "槽位 \(i + 1)", en: "Slot \(i + 1)"), selection: slotBinding(i)) {
                    ForEach(slotOptions, id: \.self) { Text(localizedToneName($0, language: store.language)).tag($0) }
                }
            }
        } header: {
            Text(jevLocalized(store.language, zh: "槽位（每个话术每次出 2 条）", en: "Slots (2 suggestions per tone)"))
        } footer: {
            Text(jevLocalized(store.language, zh: "「\(NONE_LABEL)」= 该槽关闭。键盘上候选按槽位顺序展示，最多 \(MAX_SLOTS) 槽 × 2 条。", en: "\"Off\" disables a slot. Suggestions follow slot order, up to \(MAX_SLOTS) slots × 2."))
        }
    }

    private func slotBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { store.config.slots.indices.contains(i) ? store.config.slots[i] : NONE_LABEL },
            set: { newValue in
                while store.config.slots.count < MAX_SLOTS { store.config.slots.append(NONE_LABEL) }
                store.config.slots = Array(store.config.slots.prefix(MAX_SLOTS))  // 丢掉超额的历史槽位
                store.config.slots[i] = newValue
            }
        )
    }

    private var customSection: some View {
        Section {
            ForEach(store.config.customTones.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedToneName(name, language: store.language)).font(.subheadline.weight(.medium))
                    Text(store.config.customTones[name] ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                let keys = store.config.customTones.keys.sorted()
                for idx in offsets where keys.indices.contains(idx) {
                    store.config.customTones[keys[idx]] = nil
                }
            }
            Button {
                showAdd = true
            } label: {
                Label(jevLocalized(store.language, zh: "添加自定义话术", en: "Add custom tone"), systemImage: "plus")
            }
        } header: {
            Text(jevLocalized(store.language, zh: "自定义话术", en: "Custom tones"))
        } footer: {
            Text(jevLocalized(store.language, zh: "说明写清「什么语气 + 别变成什么」最管用（同 macOS 版 JEV_TONES 的建议）。同名覆盖内置。", en: "Describe the tone and what to avoid. A custom tone with the same name overrides a built-in one."))
        }
    }

    private var previewSection: some View {
        Section(jevLocalized(store.language, zh: "内置话术预览", en: "Built-in tone preview")) {
            ForEach(Array(BUILTIN_TONES.keys.enumerated()), id: \.offset) { _, name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedToneName(name, language: store.language)).font(.subheadline.weight(.medium))
                    Text(store.language == .english ? toneEnglishDescription(name) : (BUILTIN_TONES[name] ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AddToneView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(jevLocalized(store.language, zh: "名字（下拉里显示的）", en: "Name (shown in pickers)"), text: $name)
                TextField(jevLocalized(store.language, zh: "说明（什么语气 + 别变成什么）", en: "Description (tone + what to avoid)"), text: $desc, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle(jevLocalized(store.language, zh: "自定义话术", en: "Custom tone"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(jevLocalized(store.language, zh: "取消", en: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(jevLocalized(store.language, zh: "保存", en: "Save")) {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let d = desc.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !d.isEmpty, n != NONE_LABEL else { return }
                        store.config.customTones[n] = d
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              desc.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
