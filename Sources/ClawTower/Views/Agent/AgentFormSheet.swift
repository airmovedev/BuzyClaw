import SwiftUI

struct AgentFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State var name: String = ""
    @State var emoji: String = "🤖"
    @State var description: String = ""
    @State var model: String = "default"

    // Wizard state
    @State private var currentStep = 1
    @State private var selectedStyle: StyleOption? = nil
    @State private var selectedSkills: Set<String> = []
    @State private var customSkill: String = ""

    let isEditing: Bool
    let onSave: (String, String, String, String) -> Void

    // MARK: - Data

    struct StyleOption: Identifiable, Hashable {
        let id: String
        let emoji: String
        let label: String
        let prefix: String
    }

    static let styleOptions: [StyleOption] = [
        StyleOption(id: "professional", emoji: "🎯", label: "专业严谨", prefix: "专业严谨"),
        StyleOption(id: "humorous", emoji: "😄", label: "活泼幽默", prefix: "活泼幽默"),
        StyleOption(id: "warm", emoji: "🤝", label: "温暖贴心", prefix: "温暖贴心"),
        StyleOption(id: "sharp", emoji: "🔥", label: "犀利毒舌", prefix: "犀利毒舌"),
        StyleOption(id: "calm", emoji: "🧘", label: "沉稳冷静", prefix: "沉稳冷静"),
        StyleOption(id: "creative", emoji: "🎨", label: "创意发散", prefix: "创意发散"),
    ]

    static let skillOptions = ["编程", "写作", "翻译", "数据分析", "设计", "运营", "投研", "健康", "教育", "其他"]

    // MARK: - Body

    var body: some View {
        if isEditing {
            editingView
        } else {
            wizardView
        }
    }

    // MARK: - Editing (legacy form)

    private var editingView: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("名称", text: $name)
                    TextField("Emoji", text: $emoji)
                    TextField("描述", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("模型") {
                    Picker("模型", selection: $model) {
                        ForEach(AgentDraft.modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑 Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), emoji, description, model)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    // MARK: - Wizard

    private var wizardView: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { step in
                    Capsule()
                        .fill(step <= currentStep ? themeColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Content
            Group {
                switch currentStep {
                case 1: step1NameView
                case 2: step2StyleView
                case 3: step3SkillsView
                case 4: step4ModelView
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            HStack {
                if currentStep > 1 {
                    Button("上一步") { withAnimation { currentStep -= 1 } }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if currentStep < 4 {
                    Button("下一步") { withAnimation { currentStep += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(currentStep == 1 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("创建") { createAgent() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 500, minHeight: 420)
    }

    // MARK: - Steps

    private var step1NameView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("给你的 Agent 起个名字")
                .font(.title.bold())

            VStack(spacing: 12) {
                TextField("Emoji", text: $emoji)
                    .font(.system(size: 40))
                    .multilineTextAlignment(.center)
                    .frame(width: 80)

                TextField("Agent 名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            Spacer()
        }
        .padding()
    }

    private var step2StyleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("选择 TA 的性格")
                .font(.title.bold())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                ForEach(Self.styleOptions) { style in
                    Button {
                        selectedStyle = style
                    } label: {
                        VStack(spacing: 6) {
                            Text(style.emoji).font(.title)
                            Text(style.label).font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedStyle == style ? themeColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedStyle == style ? themeColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .padding()
    }

    private var step3SkillsView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("TA 擅长什么？")
                .font(.title.bold())

            FlowLayout(spacing: 8) {
                ForEach(Self.skillOptions, id: \.self) { skill in
                    Button {
                        if selectedSkills.contains(skill) {
                            selectedSkills.remove(skill)
                        } else {
                            selectedSkills.insert(skill)
                        }
                    } label: {
                        Text(skill)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedSkills.contains(skill) ? themeColor.opacity(0.15) : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedSkills.contains(skill) ? themeColor : Color.clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)

            HStack {
                TextField("自定义能力…", text: $customSkill)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCustomSkill() }
                Button("添加") { addCustomSkill() }
                    .disabled(customSkill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 300)

            Spacer()
        }
        .padding()
    }

    private var step4ModelView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("选择默认模型")
                .font(.title.bold())

            VStack(spacing: 8) {
                ForEach(AgentDraft.modelOptions, id: \.self) { option in
                    Button {
                        model = option
                    } label: {
                        HStack {
                            Text(option)
                                .fontWeight(model == option ? .semibold : .regular)
                            Spacer()
                            if model == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(themeColor)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model == option ? themeColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(model == option ? themeColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 360)
            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func addCustomSkill() {
        let trimmed = customSkill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedSkills.insert(trimmed)
        customSkill = ""
    }

    private func buildDescription() -> String {
        var parts: [String] = []
        if let style = selectedStyle {
            parts.append("【\(style.prefix)】")
        }
        if !selectedSkills.isEmpty {
            parts.append("擅长：\(selectedSkills.sorted().joined(separator: "、"))")
        }
        return parts.joined(separator: " ")
    }

    private func createAgent() {
        let desc = buildDescription()
        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), emoji, desc, model)
        dismiss()
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
