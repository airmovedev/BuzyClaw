import SwiftUI

enum SkillFilter: String, CaseIterable {
    case all = "全部"
    case enabled = "已启用"
    case needsConfig = "需配置"
}

struct SkillsView: View {
    @State private var service = SkillsService()
    @State private var searchText = ""
    @State private var filter: SkillFilter = .all

    private var filteredSkills: [Skill] {
        var result = service.skills

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                ($0.description?.lowercased().contains(query) ?? false)
            }
        }

        switch filter {
        case .all: break
        case .enabled:
            result = result.filter { $0.status == .ready }
        case .needsConfig:
            result = result.filter { $0.status == .missingDeps }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索技能…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 240)

                Picker("筛选", selection: $filter) {
                    ForEach(SkillFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Text("\(filteredSkills.count) 个技能")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Content
            if service.isLoading {
                Spacer()
                ProgressView("加载中…")
                Spacer()
            } else if let error = service.errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await service.loadSkills() }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            } else if filteredSkills.isEmpty {
                Spacer()
                Text("没有匹配的技能")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(filteredSkills) { skill in
                        SkillRowView(skill: skill, service: service)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("技能库")
        .task {
            await service.loadSkills()
        }
    }
}

// MARK: - Skill Row

private struct SkillRowView: View {
    let skill: Skill
    let service: SkillsService
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            SkillDetailView(skill: skill, service: service)
        } label: {
            HStack(spacing: 8) {
                Text(skill.displayEmoji)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.body.weight(.medium))
                    if let desc = skill.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Source label
                Text(skill.sourceLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sourceColor(skill.source).opacity(0.15))
                    .foregroundStyle(sourceColor(skill.source))
                    .clipShape(Capsule())

                // Status label
                statusLabel(skill.status)
            }
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "openclaw-bundled": return .blue
        case "openclaw-extra": return .purple
        case "openclaw-workspace": return .orange
        default: return .gray
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: Skill.Status) -> some View {
        switch status {
        case .ready:
            Label("就绪", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .missingDeps:
            Label("缺依赖", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .disabled:
            Label("已禁用", systemImage: "nosign")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Skill Detail

private struct SkillDetailView: View {
    let skill: Skill
    let service: SkillsService
    @State private var isEnabled: Bool

    init(skill: Skill, service: SkillsService) {
        self.skill = skill
        self.service = service
        self._isEnabled = State(initialValue: !skill.disabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let desc = skill.description {
                Text(desc)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Missing dependencies
            if !skill.missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缺失依赖")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    if !skill.missing.bins.isEmpty {
                        Text("命令行工具: \(skill.missing.bins.joined(separator: ", "))")
                            .font(.caption)
                    }
                    if !skill.missing.anyBins.isEmpty {
                        Text("可选工具（任一）: \(skill.missing.anyBins.joined(separator: ", "))")
                            .font(.caption)
                    }
                    if !skill.missing.env.isEmpty {
                        Text("环境变量: \(skill.missing.env.joined(separator: ", "))")
                            .font(.caption)
                    }
                    if !skill.missing.config.isEmpty {
                        Text("配置项: \(skill.missing.config.joined(separator: ", "))")
                            .font(.caption)
                    }
                    if !skill.missing.os.isEmpty {
                        Text("不支持的系统: \(skill.missing.os.joined(separator: ", "))")
                            .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Toggle("启用", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isEnabled) { _, newValue in
                        service.setSkillEnabled(name: skill.name, enabled: newValue)
                    }

                Spacer()

                if let homepage = skill.homepage, let url = URL(string: homepage) {
                    Link(destination: url) {
                        Label("主页", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
