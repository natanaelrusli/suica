import Charts
import SuicaCore
import SwiftUI

private struct SeriesStyle {
    let name: String
    let color: Color
    let symbol: String
    let value: (DayStats) -> Int
}

private struct BarPoint: Identifiable {
    let day: String
    let series: String
    let count: Int
    var id: String { "\(day)|\(series)" }
}

struct StatisticsView: View {
    let window: WindowModel
    @State private var wide = false

    private let series = [
        SeriesStyle(name: Copy.reviewRequests, color: .blue, symbol: "person.crop.circle.badge.questionmark") {
            $0.reviewRequests
        },
        SeriesStyle(name: Copy.activity, color: .orange, symbol: "bubble.left.and.bubble.right") { $0.activity },
        SeriesStyle(name: Copy.nudgesSent, color: .green, symbol: "hand.wave") { $0.nudgesSent },
        SeriesStyle(name: Copy.noticesSent, color: .purple, symbol: "checkmark.bubble") { $0.noticesSent },
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let stats = window.stats {
                    countTiles(stats.days)
                    // Wide: the chart takes the free width and the health figures sit beside it.
                    let chartCard = Card(title: Copy.chartTitle, symbol: "chart.bar.xaxis") { chart(stats.days) }
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            chartCard
                            VStack(spacing: 16) {
                                pollsCard(stats)
                                turnaroundCard(stats)
                            }
                            .frame(width: 320)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            pollsCard(stats)
                            turnaroundCard(stats)
                        }
                        chartCard
                    }
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(20)
            .motion(value: window.errorText)
            .motion(value: window.stats)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 980, $wide)
        }
    }

    // MARK: Tiles

    private func countTiles(_ days: [DayStats]) -> some View {
        // One row of four when there is room, two by two otherwise, so the tiles always fill the width.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: wide ? 4 : 2),
            spacing: 12
        ) {
            ForEach(series, id: \.name) { style in
                StatTile(
                    title: style.name, value: "\(days.reduce(0) { $0 + style.value($1) })",
                    symbol: style.symbol, tint: style.color, caption: Copy.last14Days
                ) {
                    sparkline(style, days)
                }
            }
        }
    }

    private func sparkline(_ style: SeriesStyle, _ days: [DayStats]) -> some View {
        Chart(Array(days.enumerated()), id: \.offset) { index, day in
            AreaMark(x: .value(Copy.chartDay, index), y: .value(Copy.chartCount, style.value(day)))
                .foregroundStyle(style.color.opacity(0.18))
                .interpolationMethod(.monotone)
            LineMark(x: .value(Copy.chartDay, index), y: .value(Copy.chartCount, style.value(day)))
                .foregroundStyle(style.color)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 72, height: 30)
        .accessibilityHidden(true)
    }

    private func pollsCard(_ stats: StatsDocument) -> some View {
        Card(title: Copy.pollHealth, symbol: "waveform.path.ecg") {
            pollRow(Copy.last24Hours, stats.polls24h)
            pollRow(Copy.last7Days, stats.polls7d)
        }
    }

    private func pollRow(_ title: String, _ counts: PollCounts) -> some View {
        let total = counts.ok + counts.failed
        let share = total == 0 ? 0 : Double(counts.ok) / Double(total)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Copy.pollsOkFailed(ok: counts.ok, failed: counts.failed))
                    .monospacedDigit()
                    .foregroundStyle(counts.failed > 0 ? .orange : .secondary)
            }
            .font(.callout)
            // Drawn by hand: a ProgressView loses its tint while the window is inactive.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(counts.failed == 0 ? Color.green : (share >= 0.9 ? Color.orange : Color.red))
                        .frame(width: proxy.size.width * share)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(Copy.pollsOkFailed(ok: counts.ok, failed: counts.failed))
        }
    }

    private func turnaroundCard(_ stats: StatsDocument) -> some View {
        Card(title: Copy.turnaroundHeading, symbol: "timer") {
            turnaroundRow(Copy.ownerTurnaround, stats.ownerAfterRequest)
            Divider()
            turnaroundRow(Copy.reviewerTurnaround, stats.reviewerAfterNudge)
        }
    }

    private func turnaroundRow(_ title: String, _ turnaround: Turnaround) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let median = turnaround.medianMinutes {
                Text(Copy.median(Copy.minutes(median))).font(.title3.weight(.semibold))
                if let p90 = turnaround.p90Minutes {
                    Text(Copy.p90(Copy.minutes(p90))).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(Copy.noData).font(.title3).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func points(_ days: [DayStats]) -> [BarPoint] {
        days.flatMap { day in
            series.map { BarPoint(day: day.day, series: $0.name, count: $0.value(day)) }
        }
    }

    private func chart(_ days: [DayStats]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(points(days)) { point in
                BarMark(
                    x: .value(Copy.chartDay, point.day),
                    y: .value(Copy.chartCount, point.count)
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value(Copy.chartSeries, point.series))
                .accessibilityLabel("\(Self.shortLabel(point.day)), \(point.series)")
                .accessibilityValue("\(point.count)")
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let day = value.as(String.self) { Text(Self.shortLabel(day)) }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .center)
            .frame(minHeight: wide ? 360 : 280)
        }
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
