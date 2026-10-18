import Charts
import SuicaCore
import SwiftUI

private struct TokenKind {
    let name: String
    let color: Color
    let value: (DayUsage) -> Int
}

private struct TokenPoint: Identifiable {
    let day: String
    let kind: String
    let count: Int
    var id: String { "\(day)|\(kind)" }
}

/// Language model tokens the agent used, by period, purpose and day.
struct UsageView: View {
    let window: WindowModel
    @State private var wide = false

    private let kinds = [
        TokenKind(name: Copy.inputTokens, color: .blue) { $0.inputTokens },
        TokenKind(name: Copy.outputTokens, color: .green) { $0.outputTokens },
        TokenKind(name: Copy.cacheReadTokens, color: .teal) { $0.cacheReadTokens },
        TokenKind(name: Copy.cacheCreationTokens, color: .orange) { $0.cacheCreationTokens },
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let usage = window.usage {
                    if usage.last30d.runs == 0 { NoticeBox(text: Copy.noTokenUsage, tint: .secondary) }
                    periodTiles(usage)
                    let chartCard = Card(title: Copy.tokensChartTitle, symbol: "chart.bar.xaxis") {
                        chart(usage.days)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            chartCard
                            purposeCard(usage).frame(width: 340)
                        }
                    } else {
                        purposeCard(usage)
                        chartCard
                    }
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(20)
            .motion(value: window.errorText)
            .motion(value: window.usage)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 980, $wide)
        }
    }

    // MARK: Tiles

    private func periodTiles(_ usage: UsageDocument) -> some View {
        let periods = [
            (Copy.last24Hours, usage.last24h, "clock"),
            (Copy.last7Days, usage.last7d, "calendar"),
            (Copy.last30Days, usage.last30d, "calendar.badge.clock"),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(periods, id: \.0) { title, totals, symbol in
                StatTile(
                    title: title, value: Copy.tokens(totals.allTokens), symbol: symbol, tint: .indigo,
                    caption: Copy.runs(totals.runs))
            }
        }
    }

    // MARK: Purposes

    private func purposeCard(_ usage: UsageDocument) -> some View {
        let largest = max(usage.byPurpose.map(\.totals.allTokens).max() ?? 0, 1)
        return Card(title: Copy.byPurpose, symbol: "square.stack.3d.up") {
            if usage.byPurpose.isEmpty {
                Text(Copy.noData).font(.title3).foregroundStyle(.tertiary)
            }
            ForEach(Array(usage.byPurpose.enumerated()), id: \.element.purpose) { index, purpose in
                if index > 0 { Divider() }
                purposeRow(purpose, share: Double(purpose.totals.allTokens) / Double(largest))
            }
        }
    }

    private func purposeRow(_ purpose: PurposeUsage, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.purpose(purpose.purpose)).font(.callout.weight(.medium))
                Spacer()
                Text(Copy.tokens(purpose.totals.allTokens)).font(.callout.weight(.semibold).monospacedDigit())
            }
            // Drawn by hand: a ProgressView loses its tint while the window is inactive.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.indigo).frame(width: proxy.size.width * share)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(
                [
                    Copy.runs(purpose.runs),
                    "\(Copy.inputTokens) \(Copy.tokens(purpose.inputTokens))",
                    "\(Copy.outputTokens) \(Copy.tokens(purpose.outputTokens))",
                    "\(Copy.cacheReadTokens) \(Copy.tokens(purpose.cacheReadTokens))",
                    "\(Copy.cacheCreationTokens) \(Copy.tokens(purpose.cacheCreationTokens))",
                ].joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func points(_ days: [DayUsage]) -> [TokenPoint] {
        days.flatMap { day in kinds.map { TokenPoint(day: day.day, kind: $0.name, count: $0.value(day)) } }
    }

    private func chart(_ days: [DayUsage]) -> some View {
        Chart(points(days)) { point in
            BarMark(x: .value(Copy.chartDay, point.day), y: .value(Copy.chartTokens, point.count))
                .foregroundStyle(by: .value(Copy.chartSeries, point.kind))
                .accessibilityLabel("\(Self.shortLabel(point.day)), \(point.kind)")
                .accessibilityValue(Copy.tokens(point.count))
        }
        .chartForegroundStyleScale(domain: kinds.map(\.name), range: kinds.map(\.color))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let day = value.as(String.self) { Text(Self.shortLabel(day)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(Copy.tokens(count)) }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .center)
        .frame(minHeight: wide ? 360 : 280)
    }

    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// `YYYY-MM-DD` as a short local label ("Oct 16"); anything else is shown cleaned.
    private static func shortLabel(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return DisplayText.clean(day, max: 12) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
