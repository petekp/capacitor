import SwiftUI

enum ArtifactTab: String, CaseIterable {
    case plans = "Plans"
    case skills = "Skills"
    case commands = "Commands"
    case agents = "Agents"

    var icon: String {
        switch self {
        case .plans: return "doc.text"
        case .skills: return "sparkles"
        case .commands: return "terminal"
        case .agents: return "person.2"
        }
    }
}

struct ArtifactsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @StateObject private var plansManager = PlansManager()
    @State private var selectedTab: ArtifactTab = .plans
    @State private var searchText = ""

    private var skills: [Artifact] {
        appState.artifacts.filter { $0.artifactType == "skill" }
    }

    private var commands: [Artifact] {
        appState.artifacts.filter { $0.artifactType == "command" }
    }

    private var agents: [Artifact] {
        appState.artifacts.filter { $0.artifactType == "agent" }
    }

    var body: some View {
        VStack(spacing: 0) {
            ArtifactTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .plans:
                        PlansTab(plansManager: plansManager, searchText: $searchText)
                    case .skills:
                        ArtifactListTab(
                            artifacts: skills,
                            artifactType: .skills,
                            searchText: $searchText
                        )
                    case .commands:
                        ArtifactListTab(
                            artifacts: commands,
                            artifactType: .commands,
                            searchText: $searchText
                        )
                    case .agents:
                        ArtifactListTab(
                            artifacts: agents,
                            artifactType: .agents,
                            searchText: $searchText
                        )
                    }
                }
                .padding()
            }
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            plansManager.loadPlans()
        }
    }
}

struct ArtifactTabBar: View {
    @Binding var selectedTab: ArtifactTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ArtifactTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(AppTypography.label)
                        Text(tab.rawValue)
                            .font(AppTypography.labelMedium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedTab == tab ? Color.white.opacity(0.1) : Color.clear)
                    .foregroundColor(selectedTab == tab ? .white.opacity(0.9) : .white.opacity(0.5))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }
}

struct PlansTab: View {
    @ObservedObject var plansManager: PlansManager
    @Binding var searchText: String
    @State private var sortOrder: PlanSortOrder = .date
    @State private var selectedPlan: Plan?
    @State private var statusFilter: PlanStatus?

    enum PlanSortOrder: String, CaseIterable {
        case date = "Date"
        case name = "Name"
        case size = "Size"
        case status = "Status"
    }

    var filteredPlans: [Plan] {
        var plans = plansManager.allPlans

        if let statusFilter = statusFilter {
            plans = plans.filter { $0.status == statusFilter }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            plans = plans.filter { plan in
                plan.name.lowercased().contains(query) ||
                plan.content.lowercased().contains(query)
            }
        }

        switch sortOrder {
        case .date:
            plans.sort { $0.modifiedDate ?? .distantPast > $1.modifiedDate ?? .distantPast }
        case .name:
            plans.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .size:
            plans.sort { $0.wordCount > $1.wordCount }
        case .status:
            let statusOrder: [PlanStatus] = [.inProgress, .active, .implemented, .archived]
            plans.sort { statusOrder.firstIndex(of: $0.status)! < statusOrder.firstIndex(of: $1.status)! }
        }

        return plans
    }

    var statusCounts: [PlanStatus: Int] {
        var counts: [PlanStatus: Int] = [:]
        for status in PlanStatus.allCases {
            counts[status] = plansManager.allPlans.filter { $0.status == status }.count
        }
        return counts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(AppTypography.label)
                        .foregroundColor(.white.opacity(0.4))

                    TextField("Search plans...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(AppTypography.labelMedium)
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)

                Menu {
                    ForEach(PlanSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            HStack {
                                Text(order.rawValue)
                                if sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(AppTypography.badge)
                        Text(sortOrder.rawValue)
                            .font(AppTypography.label)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundColor(.white.opacity(0.6))
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    StatusFilterChip(
                        label: "All",
                        count: plansManager.allPlans.count,
                        isSelected: statusFilter == nil,
                        color: .white
                    ) {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            statusFilter = nil
                        }
                    }

                    ForEach(PlanStatus.allCases, id: \.self) { status in
                        StatusFilterChip(
                            label: status.rawValue,
                            count: statusCounts[status] ?? 0,
                            isSelected: statusFilter == status,
                            color: statusColor(for: status)
                        ) {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                statusFilter = statusFilter == status ? nil : status
                            }
                        }
                    }
                }
            }

            if plansManager.allPlans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.3))
                    Text("No plans yet")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.white.opacity(0.5))
                    Text("Create plans using Plan Mode (Shift+Tab)")
                        .font(AppTypography.label)
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if filteredPlans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.3))
                    Text("No matching plans")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Text("\(filteredPlans.count) plan\(filteredPlans.count == 1 ? "" : "s")")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.4))

                LazyVStack(spacing: 8) {
                    ForEach(filteredPlans) { plan in
                        PlanCardView(
                            plan: plan,
                            isSelected: selectedPlan?.id == plan.id,
                            onStatusChange: { newStatus in
                                plansManager.updatePlanStatus(plan.id, status: newStatus)
                            }
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                if selectedPlan?.id == plan.id {
                                    selectedPlan = nil
                                } else {
                                    selectedPlan = plan
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusColor(for status: PlanStatus) -> Color {
        switch status {
        case .active: return .blue
        case .inProgress: return .orange
        case .implemented: return .green
        case .archived: return .gray
        }
    }
}

struct StatusFilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(AppTypography.badge)
                if count > 0 {
                    Text("\(count)")
                        .font(AppTypography.captionSmall.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? color.opacity(0.3) : Color.white.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.15) : Color.white.opacity(0.03))
            .foregroundColor(isSelected ? color : .white.opacity(0.5))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct PlanCardView: View {
    let plan: Plan
    let isSelected: Bool
    var onStatusChange: ((PlanStatus) -> Void)?

    private var statusColor: Color {
        switch plan.status {
        case .active: return .blue
        case .inProgress: return .orange
        case .implemented: return .green
        case .archived: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.name)
                    .font(AppTypography.bodySecondary.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))

                Menu {
                    ForEach(PlanStatus.allCases, id: \.self) { status in
                        Button {
                            onStatusChange?(status)
                        } label: {
                            HStack {
                                Image(systemName: status.icon)
                                Text(status.rawValue)
                                if plan.status == status {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: plan.status.icon)
                            .font(AppTypography.captionSmall)
                        Text(plan.status.rawValue)
                            .font(AppTypography.captionSmall.weight(.medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(AppTypography.badge)
                    Text("\(plan.wordCount) words")
                        .font(AppTypography.badge)
                }
                .foregroundColor(.white.opacity(0.4))
            }

            if !isSelected {
                Text(plan.preview)
                    .font(AppTypography.label)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }

            if let modifiedDate = plan.modifiedDate {
                Text(formattedDate(modifiedDate))
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.3))
            }

            if isSelected {
                Divider()
                    .background(Color.white.opacity(0.1))

                ScrollView {
                    Text(plan.content)
                        .font(AppTypography.monoCaption)
                        .foregroundColor(.white.opacity(0.7))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.content, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(AppTypography.badge)
                            Text("Copy")
                                .font(AppTypography.badge)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))

                    Spacer()

                    Button {
                        if let url = URL(string: "file://\(NSHomeDirectory())/.claude/plans/\(plan.filename)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(AppTypography.badge)
                            Text("Open")
                                .font(AppTypography.badge)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(isSelected ? 0.06 : 0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(isSelected ? 0.3 : 0.1), lineWidth: 1)
        )
    }

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Today, \(formatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
}

struct ComingSoonPlaceholder: View {
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.title)
                .foregroundColor(.white.opacity(0.2))

            Text("\(title) coming soon")
                .font(AppTypography.body.weight(.semibold))
                .foregroundColor(.white.opacity(0.6))

            Text(description)
                .font(AppTypography.labelMedium)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

enum ArtifactListType {
    case skills
    case commands
    case agents

    var singular: String {
        switch self {
        case .skills: return "skill"
        case .commands: return "command"
        case .agents: return "agent"
        }
    }

    var plural: String {
        switch self {
        case .skills: return "skills"
        case .commands: return "commands"
        case .agents: return "agents"
        }
    }

    var icon: String {
        switch self {
        case .skills: return "sparkles"
        case .commands: return "terminal"
        case .agents: return "person.2"
        }
    }

    var emptyMessage: String {
        switch self {
        case .skills: return "Create skills in ~/.claude/skills/"
        case .commands: return "Create commands in ~/.claude/commands/"
        case .agents: return "Create agents in ~/.claude/agents/"
        }
    }

    var color: Color {
        switch self {
        case .skills: return .purple
        case .commands: return .cyan
        case .agents: return .orange
        }
    }
}

struct ArtifactListTab: View {
    let artifacts: [Artifact]
    let artifactType: ArtifactListType
    @Binding var searchText: String
    @State private var selectedArtifact: String?

    var filteredArtifacts: [Artifact] {
        if searchText.isEmpty {
            return artifacts
        }
        let query = searchText.lowercased()
        return artifacts.filter { artifact in
            artifact.name.lowercased().contains(query) ||
            artifact.description.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AppTypography.label)
                    .foregroundColor(.white.opacity(0.4))

                TextField("Search \(artifactType.plural)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)

            if artifacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: artifactType.icon)
                        .font(.title)
                        .foregroundColor(.white.opacity(0.3))
                    Text("No \(artifactType.plural) yet")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.white.opacity(0.5))
                    Text(artifactType.emptyMessage)
                        .font(AppTypography.label)
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if filteredArtifacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.3))
                    Text("No matching \(artifactType.plural)")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Text("\(filteredArtifacts.count) \(filteredArtifacts.count == 1 ? artifactType.singular : artifactType.plural)")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.4))

                LazyVStack(spacing: 8) {
                    ForEach(filteredArtifacts, id: \.path) { artifact in
                        ArtifactCardView(
                            artifact: artifact,
                            artifactType: artifactType,
                            isSelected: selectedArtifact == artifact.path
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                if selectedArtifact == artifact.path {
                                    selectedArtifact = nil
                                } else {
                                    selectedArtifact = artifact.path
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ArtifactCardView: View {
    let artifact: Artifact
    let artifactType: ArtifactListType
    let isSelected: Bool
    @State private var fileContent: String?

    private var isFromPlugin: Bool {
        !artifact.source.isEmpty && artifact.source != "Global" && artifact.source != "user"
    }

    private var sourceLabel: String {
        artifact.source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: artifactType.icon)
                    .font(AppTypography.labelMedium)
                    .foregroundColor(artifactType.color.opacity(0.8))

                Text(artifact.name)
                    .font(AppTypography.bodySecondary.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))

                if isFromPlugin {
                    Text(sourceLabel)
                        .font(AppTypography.captionSmall.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white.opacity(0.5))
                        .cornerRadius(4)
                }

                Spacer()
            }

            if !artifact.description.isEmpty {
                Text(artifact.description)
                    .font(AppTypography.label)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(isSelected ? nil : 2)
            }

            if isSelected {
                Divider()
                    .background(Color.white.opacity(0.1))

                if let content = fileContent {
                    ScrollView {
                        Text(content)
                            .font(AppTypography.monoCaption)
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 250)
                } else {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Loading content...")
                            .font(AppTypography.label)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                HStack {
                    Button {
                        if let content = fileContent {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(content, forType: .string)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(AppTypography.badge)
                            Text("Copy")
                                .font(AppTypography.badge)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                    .disabled(fileContent == nil)

                    Spacer()

                    Button {
                        let url = URL(fileURLWithPath: artifact.path)
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(AppTypography.badge)
                            Text("Open")
                                .font(AppTypography.badge)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                }
            }

            Text(artifact.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(AppTypography.monoCaption)
                .foregroundColor(.white.opacity(0.3))
                .lineLimit(1)
        }
        .padding(12)
        .background(Color.white.opacity(isSelected ? 0.06 : 0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(artifactType.color.opacity(isSelected ? 0.3 : 0.1), lineWidth: 1)
        )
        .onChange(of: isSelected) { _, selected in
            if selected && fileContent == nil {
                loadContent()
            }
        }
        .onAppear {
            if isSelected && fileContent == nil {
                loadContent()
            }
        }
    }

    private func loadContent() {
        DispatchQueue.global(qos: .userInitiated).async {
            let content = try? String(contentsOfFile: artifact.path, encoding: .utf8)
            DispatchQueue.main.async {
                self.fileContent = content ?? "Unable to load file content"
            }
        }
    }
}
