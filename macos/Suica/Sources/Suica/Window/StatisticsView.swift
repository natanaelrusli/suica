import Charts
import SuicaCore
import SwiftUI

private struct SeriesStyle {
    let name: String
    let color: Color
}

private struct BarPoint: Identifiable {
    let day: String
    let series: String
    let count: Int
    var id: String { "\(day)|\(series)" }
}

struct StatisticsView: View {
    let window: WindowModel

    private let series = [
        SeriesStyle(name: Copy.reviewRequests, color: .blue),
        SeriesStyle(name: Copy.activity, color: .orange),
        SeriesStyle(name: Copy.nudgesSent, color: .green),
        SeriesStyle(name: Copy.noticesSent, color: .purple),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let stats = window.stats {
                    tiles(stats)
                    chart(stats.days)
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(20)
        }
    }

    // MARK: Tiles

    private func tiles(_ stats: StatsDocument) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], spacing: 12) {
            tile(Copy.polls24h, Copy.pollsOkFailed(ok: stats.polls24h.ok, failed: stats.polls24h.failed))
            tile(Copy.reviewRequests, "\(stats.days.reduce(0) { $0 + $1.reviewRequests })", Copy.last14Days)
            tile(Copy.activity, "\(stats.days.reduce(0) { $0 + $1.activity })", Copy.last14Days)
            tile(Copy.nudgesSent, "\(stats.days.reduce(0) { $0 + $1.nudgesSent })", Copy.last14Days)
            tile(Copy.noticesSent, "\(stats.days.reduce(0) { $0 + $1.noticesSent })", Copy.last14Days)
            turnaroundTile(Copy.ownerTurnaround, stats.ownerAfterRequest)
            turnaroundTile(Copy.reviewerTurnaround, stats.reviewerAfterNudge)
        }
    }

    private func turnaroundTile(_ title: String, _ turnaround: Turnaround) -> some View {
        if let median = turnaround.medianMinutes {
            tile(title, Copy.minutes(median), turnaround.p90Minutes.map { Copy.p90(Copy.minutes($0)) })
        } else {
            tile(title, Copy.noData)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func points(_ days: [DayStats]) -> [BarPoint] {
        days.flatMap { day in
            [
                BarPoint(day: day.day, series: series[0].name, count: day.reviewRequests),
                BarPoint(day: day.day, series: series[1].name, count: day.activity),
                BarPoint(day: day.day, series: series[2].name, count: day.nudgesSent),
                BarPoint(day: day.day, series: series[3].name, count: day.noticesSent),
            ]
        }
    }

    private func chart(_ days: [DayStats]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.chartTitle).font(.headline)
            Chart(points(days)) { point in
                BarMark(
                    x: .value(Copy.chartDay, point.day),
                    y: .value(Copy.chartCount, point.count)
                )
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
            .frame(minHeight: 280)
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
