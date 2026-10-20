import SuicaCore
import SwiftUI

/// A page under Statistics: one ranking of people, or your slowest approvals, from `suica stats`.
struct StatisticsPageView: View {
    let window: WindowModel
    let page: StatisticsPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let stats = window.stats {
                    Card(title: "\(page.title), \(Copy.last90Days.lowercased())", symbol: page.symbol) {
                        Text(hint).font(.callout).foregroundStyle(.secondary)
                        content(stats)
                    }
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(20)
            .motion(value: window.errorText)
            .motion(value: window.stats)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hint: String {
        switch page {
        case .peopleIReview: Copy.peopleIReviewHint
        case .peopleWhoReviewMe: Copy.peopleWhoReviewMeHint
        case .slowestApprovals: Copy.slowestApprovalsHint
        }
    }

    @ViewBuilder private func content(_ stats: StatsDocument) -> some View {
        switch page {
        case .peopleIReview: ranking(stats.peopleIReview ?? [])
        case .peopleWhoReviewMe: ranking(stats.peopleWhoReviewMe ?? [])
        case .slowestApprovals: approvals(stats.slowestApprovals ?? [])
        }
    }

    private func noData() -> some View {
        Text(Copy.noData).font(.title3).foregroundStyle(.tertiary).padding(.vertical, 8)
    }

    // MARK: People

    @ViewBuilder private func ranking(_ people: [PersonCount]) -> some View {
        if people.isEmpty {
            noData()
        } else {
            let most = people.map(\.mergeRequests).max() ?? 1
            ForEach(Array(people.enumerated()), id: \.element.username) { index, person in
                if index > 0 { Divider() }
                personRow(rank: index + 1, person, share: Double(person.mergeRequests) / Double(max(most, 1)))
            }
        }
    }

    private func personRow(rank: Int, _ person: PersonCount, share: Double) -> some View {
        let name = DisplayText.clean(person.name, max: 80)
        return HStack(spacing: 10) {
            rankLabel(rank)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.body.weight(.medium)).lineLimit(1)
                    Text("@\(DisplayText.clean(person.username, max: 60))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Copy.mergeRequestCount(person.mergeRequests))
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                // Drawn by hand, as on Statistics: a ProgressView loses its tint while the window is inactive.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(page.tint).frame(width: proxy.size.width * share)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(name)")
        .accessibilityValue(Copy.mergeRequestCount(person.mergeRequests))
    }

    private func rankLabel(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 22, alignment: .trailing)
            .accessibilityHidden(true)
    }

    // MARK: Approvals

    @ViewBuilder private func approvals(_ rows: [SlowApproval]) -> some View {
        if rows.isEmpty {
            noData()
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.mrKey) { index, row in
                if index > 0 { Divider() }
                approvalRow(rank: index + 1, row)
            }
        }
    }

    private func approvalRow(rank: Int, _ row: SlowApproval) -> some View {
        let title = DisplayText.clean(row.title)
        let opened = Date(timeIntervalSince1970: Double(row.openedAt) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            rankLabel(rank)
            VStack(alignment: .leading, spacing: 2) {
                // Only an http(s) link is opened; anything else shows as plain text.
                if let url = DisplayText.safeURL(row.url) {
                    Link(title, destination: url).font(.body.weight(.medium)).lineLimit(2)
                } else {
                    Text(title).font(.body.weight(.medium)).lineLimit(2)
                }
                Text(
                    "\(DisplayText.shortKey(row.mrKey)) · \(Copy.openedOn(opened)) · "
                        + Copy.approvedBy(DisplayText.clean(row.approver.name, max: 80))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Copy.duration(row.minutes))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(page.tint)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
