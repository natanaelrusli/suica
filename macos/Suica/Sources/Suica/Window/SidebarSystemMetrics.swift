import SuicaCore
import SwiftUI

struct SidebarSystemMetrics: View {
    let openSystem: () -> Void
    @State private var windowVisible = true
    @State private var cpuUsage: Double?
    @State private var vitals: SystemVitals?

    var body: some View {
        Button(action: openSystem) {
            VStack(spacing: 4) {
                metric(Copy.cpu, symbol: "cpu", value: cpuUsage.map(Copy.percent))
                metric(Copy.ram, symbol: "memorychip", value: vitals?.memory.map { Copy.memoryBytes($0.used) })
                metric(Copy.fanSpeed, symbol: "fan", value: fanSpeed)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Copy.openSection(WindowSection.system.title))
        .accessibilityHint(Text(Copy.openSection(WindowSection.system.title)))
        .background(WindowVisibility { windowVisible = $0 })
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await sample()
        }
    }

    private var fanSpeed: String? {
        guard let speeds = vitals?.fanRPM else { return nil }
        return speeds.isEmpty ? Copy.fanless : Copy.fanRPM(speeds)
    }

    private func metric(_ title: String, symbol: String, value: String?) -> some View {
        HStack(spacing: 5) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            Text(value ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(value ?? Copy.readingUnavailable))
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func sample() async {
        var previousCPU: CPUTicks?
        while !Task.isCancelled {
            let next = await SystemReader.readVitals()
            guard !Task.isCancelled else { return }
            cpuUsage = previousCPU.flatMap { old in next.cpu.map { SystemMath.cpuUsage(from: old, to: $0) } }
            previousCPU = next.cpu
            vitals = next
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
