import Charts
import SuicaCore
import SwiftUI

/// How hard this Mac is working: CPU, memory, disk, network, battery and heat, and the processes
/// using the most. It samples every two seconds while it is on screen and keeps nothing after.
struct SystemView: View {
    @State private var model = SystemModel()
    @State private var wide = false
    /// False while the window is minimized, hidden or covered: nothing is sampled then.
    @State private var windowVisible = true
    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.gap) {
                if let readout = model.latest {
                    cards(readout)
                    processesCard
                } else {
                    ProgressView(Copy.loading)
                }
            }
            .padding(metrics.gap + 4)
            .motion(value: model.latest == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 760, $wide)
        }
        .background(WindowVisibility { windowVisible = $0 })
        // Samples only while the page is on screen, and stops with it.
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await model.runSampleLoop(every: .seconds(2))
        }
    }

    // MARK: Cards

    @ViewBuilder private func cards(_ readout: SystemReadout) -> some View {
        if wide {
            // A grid, so the two cards of a row end on one line.
            Grid(horizontalSpacing: metrics.gap, verticalSpacing: metrics.gap) {
                GridRow {
                    cpuCard(readout)
                    memoryCard(readout)
                }
                GridRow {
                    networkCard
                    diskCard(readout)
                }
                GridRow {
                    if let battery = readout.battery {
                        batteryCard(battery)
                        thermalCard(readout)
                    } else {
                        thermalCard(readout).gridCellColumns(2)
                    }
                }
            }
        } else {
            cpuCard(readout)
            memoryCard(readout)
            networkCard
            diskCard(readout)
            if let battery = readout.battery { batteryCard(battery) }
            thermalCard(readout)
        }
    }

    private func cpuCard(_ readout: SystemReadout) -> some View {
        let level = model.cpuUsage.map(UsageLevel.init)
        return Card(title: Copy.cpu, symbol: "cpu", fillsHeight: wide) {
            Figure(value: model.cpuUsage.map(Copy.percent) ?? Copy.measuring, detail: Copy.cores(readout.cores))
            if !readout.loadAverages.isEmpty {
                Text(Copy.loadAverages(readout.loadAverages)).font(.caption).foregroundStyle(.secondary)
            }
            HistoryChart(
                series: [
                    HistorySeries(
                        name: Copy.cpu, color: Self.color(level, normal: .blue), values: model.history.map(\.cpu))
                ],
                top: 1)
        }
    }

    private func memoryCard(_ readout: SystemReadout) -> some View {
        Card(title: Copy.memory, symbol: "memorychip", fillsHeight: wide) {
            if let memory = readout.memory {
                let share = Double(memory.used) / Double(max(memory.total, 1))
                let color = Self.color(UsageLevel(share), normal: .teal)
                Figure(
                    value: Copy.memoryBytes(memory.used),
                    detail: Copy.usedOf(Copy.percent(share), Copy.memoryBytes(memory.total)))
                UsageBar(share: share, color: color)
                Text(Copy.swapUsed(Copy.memoryBytes(memory.swapUsed))).font(.caption).foregroundStyle(.secondary)
                HistoryChart(
                    series: [
                        HistorySeries(
                            name: Copy.memory, color: color, values: model.history.map { Double($0.memoryUsed ?? 0) })
                    ],
                    top: Double(memory.total))
            } else {
                Text(Copy.noData).foregroundStyle(.tertiary)
            }
        }
    }

    private var networkCard: some View {
        let download = model.history.map(\.download)
        let upload = model.history.map(\.upload)
        // A floor, so a quiet network does not draw its noise as peaks.
        let top = max((download + upload).max() ?? 0, 100_000) * 1.15
        return Card(title: Copy.network, symbol: "network", fillsHeight: wide) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                rateFigure(Copy.download, symbol: "arrow.down", rate: model.downloadRate, color: .blue)
                rateFigure(Copy.upload, symbol: "arrow.up", rate: model.uploadRate, color: .pink)
                Spacer(minLength: 0)
            }
            Text(Copy.lastTwoMinutes).font(.caption).foregroundStyle(.secondary)
            HistoryChart(
                series: [
                    HistorySeries(name: Copy.download, color: .blue, values: download),
                    HistorySeries(name: Copy.upload, color: .pink, values: upload),
                ],
                top: top)
        }
    }

    private func rateFigure(_ title: String, symbol: String, rate: Double?, color: Color) -> some View {
        Label {
            Text(rate.map(Copy.rate) ?? Copy.measuring)
                .font(.title3.weight(.semibold).monospacedDigit())
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).fontWeight(.bold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(rate.map(Copy.rate) ?? Copy.measuring)
    }

    private func diskCard(_ readout: SystemReadout) -> some View {
        Card(title: Copy.disk, symbol: "internaldrive", fillsHeight: wide) {
            if let disk = readout.disk {
                let share = Double(disk.used) / Double(max(disk.total, 1))
                Figure(
                    value: Copy.diskBytes(disk.used),
                    detail: Copy.usedOf(Copy.percent(share), Copy.diskBytes(disk.total)))
                UsageBar(share: share, color: Self.color(UsageLevel(share), normal: .indigo))
                Text(Copy.free(Copy.diskBytes(disk.available))).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Copy.noData).foregroundStyle(.tertiary)
            }
        }
    }

    private func batteryCard(_ battery: BatteryStatus) -> some View {
        Card(title: Copy.battery, symbol: Self.batterySymbol(battery), fillsHeight: wide) {
            Figure(value: Copy.percent(battery.charge), detail: Copy.powerState(battery.state))
            UsageBar(share: battery.charge, color: .green)
            if let minutes = battery.minutesLeft {
                Text(Copy.timeLeft(minutes)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func thermalCard(_ readout: SystemReadout) -> some View {
        Card(title: Copy.thermal, symbol: "thermometer.medium", fillsHeight: wide) {
            HStack(spacing: 8) {
                StatusDot(color: Self.color(readout.thermal), active: readout.thermal != .nominal)
                Figure(value: Copy.thermalState(readout.thermal), detail: nil)
            }
            Text(Copy.thermalHint(readout.thermal)).font(.caption).foregroundStyle(.secondary)
            Text(Copy.uptime(readout.uptime)).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Processes

    /// The rows are not animated into their new order: they change every two seconds, and the
    /// animation alone took a quarter of a core.
    private var processesCard: some View {
        let processes = model.topProcesses
        return Card(title: Copy.topProcesses, symbol: "list.number") {
            Picker(Copy.topProcesses, selection: $model.processOrder) {
                Text(Copy.cpu).tag(ProcessOrder.cpu)
                Text(Copy.memory).tag(ProcessOrder.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if processes.isEmpty {
                Text(Copy.noProcesses).foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text(Copy.processName)
                        Text(Copy.processID).gridColumnAlignment(.trailing)
                        Text(Copy.cpu).gridColumnAlignment(.trailing)
                            .fontWeight(model.processOrder == .cpu ? .semibold : nil)
                        Text(Copy.memory).gridColumnAlignment(.trailing)
                            .fontWeight(model.processOrder == .memory ? .semibold : nil)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(processes) { process in
                        GridRow {
                            Text(process.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(process.name)
                            Text(String(process.pid)).foregroundStyle(.secondary)
                            Text(Copy.processCPU(process.cpu))
                            Text(Copy.memoryBytes(process.memory))
                        }
                        .font(.callout.monospacedDigit())
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Colours

    /// The figure's own colour while normal, orange above 75 %, red above 90 %.
    private static func color(_ level: UsageLevel?, normal: Color) -> Color {
        switch level {
        case .warning: .orange
        case .critical: .red
        case .normal, nil: normal
        }
    }

    private static func color(_ thermal: ThermalLevel) -> Color {
        switch thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    private static func batterySymbol(_ battery: BatteryStatus) -> String {
        if battery.state == .charging { return "battery.100percent.bolt" }
        return switch battery.charge {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// A card's main figure, with a detail after it in grey. Not animated: the figures change every
/// two seconds, and rolling digits kept the page redrawing (about half a core in the harness).
private struct Figure: View {
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// How full something is. Drawn by hand: a ProgressView loses its tint while the window is inactive.
private struct UsageBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct HistorySeries {
    let name: String
    let color: Color
    let values: [Double]
}

private struct HistoryPoint: Identifiable {
    let series: String
    let slot: Int
    let value: Double
    var id: String { "\(series)|\(slot)" }
}

/// The last two minutes as lines, newest on the right, filling in from there as samples arrive.
private struct HistoryChart: View {
    let series: [HistorySeries]
    /// The top of the scale.
    let top: Double

    var body: some View {
        Chart {
            ForEach(series, id: \.name) { line in
                ForEach(points(line)) { point in
                    AreaMark(
                        x: .value(Copy.chartTime, point.slot), y: .value(Copy.chartUsage, point.value),
                        series: .value(Copy.chartSeries, line.name), stacking: .unstacked
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [line.color.opacity(0.3), line.color.opacity(0.02)], startPoint: .top,
                            endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value(Copy.chartTime, point.slot), y: .value(Copy.chartUsage, point.value),
                        series: .value(Copy.chartSeries, line.name)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: 0...(SystemModel.historyLength - 1))
        .chartYScale(domain: 0...max(top, 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }

    private func points(_ line: HistorySeries) -> [HistoryPoint] {
        let start = SystemModel.historyLength - line.values.count
        return line.values.enumerated().map { HistoryPoint(series: line.name, slot: start + $0, value: min($1, top)) }
    }
}
