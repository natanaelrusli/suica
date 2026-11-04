import Charts
import SuicaCore
import SwiftUI

/// What Claude Code and Codex use on this Mac would cost at API list prices, in USD or IDR.
struct AgentUsageView: View {
    let window: WindowModel
    @AppStorage("usage.currency") private var currency = "USD"

    private typealias Doc = AgentUsageDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toolbar
                if let text = window.agentUsageError { NoticeBox(text: text, tint: .red) }
                if let usage = window.agentUsage {
                    content(usage)
                } else if window.agentUsageLoading || window.agentUsageError == nil {
                    ProgressView(Copy.agentUsageLoading)
                }
            }
            .padding(20)
            .motion(value: window.agentUsageError)
            .motion(value: window.agentUsage)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A cancelled task does not stop the scan; loadAgentUsage is single-flight.
        .task { await window.loadAgentUsage() }
    }

    // MARK: Currency

    /// IDR needs a rate; without one the amounts stay in USD whatever was picked.
    private func code(_ usage: Doc) -> String { usage.rate != nil && currency == "IDR" ? "IDR" : "USD" }

    /// What the switch shows: USD while there is no rate, though IDR may be saved.
    private var shown: Binding<String> {
        Binding(
            get: { window.agentUsage.map(code) ?? currency },
            set: { currency = $0 })
    }

    private func money(_ usd: Double, _ usage: Doc) -> String {
        let style = Locale(identifier: "en_US")
        if code(usage) == "IDR", let rate = usage.rate {
            return (usd * rate.perUsd).formatted(.currency(code: "IDR").precision(.fractionLength(0)).locale(style))
        }
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(style))
    }

    /// Axis labels: "$1.2K" or "IDR 20M".
    private func shortMoney(_ usd: Double, _ usage: Doc) -> String {
        let amount = code(usage) == "IDR" ? usd * (usage.rate?.perUsd ?? 1) : usd
        return amount.formatted(
            .currency(code: code(usage)).notation(.compactName).precision(.fractionLength(0...1))
                .locale(Locale(identifier: "en_US")))
    }

    private static func tokens(_ count: Double) -> String { Copy.tokens(Int(count.rounded())) }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Picker(Copy.usageCurrency, selection: shown) {
                Text("USD").tag("USD")
                Text("IDR").tag("IDR").disabled(window.agentUsage?.rate == nil)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(Copy.usageCurrency)
            Spacer()
            if window.agentUsageLoading && window.agentUsage != nil { ProgressView().controlSize(.small) }
            Button {
                Task { await window.loadAgentUsage() }
            } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help(Copy.refresh)
            .disabled(window.agentUsageLoading)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ usage: Doc) -> some View {
        if let rate = usage.rate, rate.stale {
            NoticeBox(text: Copy.rateStale(Self.longDate(rate.date)), tint: .orange)
        }
        if usage.rate == nil { NoticeBox(text: Copy.noRate, tint: .orange) }
        if usage.unpriced.tokens > 0 || !usage.unpriced.models.isEmpty {
            NoticeBox(text: Copy.unpricedTokens(usage.unpriced.tokens, models: usage.unpriced.models), tint: .orange)
        }
        tiles(usage)
        Card(title: Copy.costChartTitle, symbol: "chart.bar.xaxis") { chart(usage) }
        modelCard(usage)
        Text(Copy.pricesFootnote(Self.longDate(usage.pricesAsOf)))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func tiles(_ usage: Doc) -> some View {
        let periods: [(String, Doc.CostTotals, String)] = [
            (Copy.last24Hours, usage.last24h, "clock"),
            (Copy.last7Days, usage.last7d, "calendar"),
            (Copy.last30Days, usage.last30d, "calendar.badge.clock"),
            (Copy.avgPerDay7d, usage.avgPerDay7d, "divide.circle"),
            (Copy.avgPerDay30d, usage.avgPerDay30d, "divide.circle"),
        ]
        // Three to a row: the periods on top, the two averages under them.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(periods, id: \.0) { title, totals, symbol in
                StatTile(
                    title: title, value: money(totals.costUsd, usage), symbol: symbol, tint: .indigo,
                    caption: "\(Self.tokens(totals.tokens)) tokens")
            }
        }
    }

    // MARK: Chart

    private func chart(_ usage: Doc) -> some View {
        // A label every fifth day, ending on the latest, so 30 of them do not overlap.
        let labelled = usage.days.enumerated().filter { (usage.days.count - 1 - $0.offset) % 5 == 0 }.map(\.element.day)
        return Chart(usage.days, id: \.day) { day in
            BarMark(x: .value(Copy.chartDay, day.day), y: .value(Copy.chartCost, day.costUsd))
                .foregroundStyle(Color.indigo)
                .accessibilityLabel(UsageView.shortLabel(day.day))
                .accessibilityValue(money(day.costUsd, usage))
        }
        .chartXAxis {
            AxisMarks(values: labelled) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let day = value.as(String.self) { Text(UsageView.shortLabel(day)) }
                }
            }
        }
        .chartYAxis {
            // On the left, so the latest day's label has room at the right edge.
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let usd = value.as(Double.self) { Text(shortMoney(usd, usage)) }
                }
            }
        }
        // Room for the latest day's label past the last bar, and for the top axis label.
        .chartPlotStyle { $0.padding(.trailing, 24) }
        .padding(.top, 8)
        .frame(minHeight: 260)
    }

    // MARK: Models

    private func modelCard(_ usage: Doc) -> some View {
        Card(title: Copy.byModel, symbol: "cpu") {
            if usage.byModel.isEmpty { Text(Copy.noModelUsage).font(.title3).foregroundStyle(.tertiary) }
            ForEach(Array(usage.byModel.enumerated()), id: \.offset) { index, model in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DisplayText.clean(model.model, max: 60)).font(.callout.weight(.medium))
                        Text("\(Self.agentName(model.agent)) · \(Self.tokens(model.tokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cost = model.costUsd {
                        Text(money(cost, usage)).font(.callout.weight(.semibold).monospacedDigit())
                    } else {
                        Text(Copy.unpricedModel).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func agentName(_ raw: String) -> String {
        switch raw {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: DisplayText.clean(raw, max: 30)
        }
    }

    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// `2026-11-02` → "2 Nov 2026"; anything else is shown cleaned.
    private static func longDate(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return DisplayText.clean(day, max: 20) }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB")))
    }
}
