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
                        ComingSoonPlaceholder(title: "Skills", description: "Browse and manage your Claude Code skills")
                    case .commands:
                        ComingSoonPlaceholder(title: "Commands", description: "View available slash commands")
                    case .agents:
                        ComingSoonPlaceholder(title: "Agents", description: "Explore your custom agents")
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
                            .font(.system(size: 10))
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))

                    TextField("Search plans...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
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
                            .font(.system(size: 9))
                        Text(sortOrder.rawValue)
                            .font(.system(size: 10))
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
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No plans yet")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                    Text("Create plans using Plan Mode (Shift+Tab)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if filteredPlans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No matching plans")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Text("\(filteredPlans.count) plan\(filteredPlans.count == 1 ? "" : "s")")
                    .font(.system(size: 9))
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
                    .font(.system(size: 9, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                            .font(.system(size: 8))
                        Text(plan.status.rawValue)
                            .font(.system(size: 8, weight: .medium))
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
                        .font(.system(size: 9))
                    Text("\(plan.wordCount) words")
                        .font(.system(size: 9))
                }
                .foregroundColor(.white.opacity(0.4))
            }

            if !isSelected {
                Text(plan.preview)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }

            if let modifiedDate = plan.modifiedDate {
                Text(formattedDate(modifiedDate))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }

            if isSelected {
                Divider()
                    .background(Color.white.opacity(0.1))

                ScrollView {
                    Text(plan.content)
                        .font(.system(size: 10, design: .monospaced))
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
                                .font(.system(size: 9))
                            Text("Copy")
                                .font(.system(size: 9))
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
                                .font(.system(size: 9))
                            Text("Open")
                                .font(.system(size: 9))
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
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.2))

            Text("\(title) coming soon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
