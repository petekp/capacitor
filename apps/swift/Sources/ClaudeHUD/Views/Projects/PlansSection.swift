import SwiftUI

struct PlansSection: View {
    let plans: [Plan]

    var body: some View {
        if plans.isEmpty {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    DetailSectionLabel(title: "PLANS")
                    Text("No planning documents")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                DetailSectionLabel(title: "PLANS")

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plans.prefix(3)) { plan in
                        PlanItem(plan: plan)
                    }

                    if plans.count > 3 {
                        Text("+\(plans.count - 3) more plan\(plans.count - 3 == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        )
    }
}

struct PlanItem: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plan.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                HStack(spacing: 2) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))

                    Text("\(plan.wordCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Text(plan.preview)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)

            if let modifiedDate = plan.modifiedDate {
                HStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.3))

                    Text(formattedDate(modifiedDate))
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.02))
        .cornerRadius(8)
    }

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDateInThisWeek(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

extension Calendar {
    func isDateInThisWeek(_ date: Date) -> Bool {
        let now = Date()
        let startOfWeek = self.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        var endOfWeek = DateComponents()
        endOfWeek.yearForWeekOfYear = startOfWeek.yearForWeekOfYear
        endOfWeek.weekOfYear = (startOfWeek.weekOfYear ?? 0) + 1
        endOfWeek.day = 0

        let startDate = self.date(from: startOfWeek) ?? now
        let endDate = self.date(from: endOfWeek) ?? now

        return date >= startDate && date <= endDate
    }
}
