import Foundation
import IOKit.ps
import Testing

@testable import SuicaCore

@Test func cpuUsageIsBusyTicksOverAllTicks() {
    let old = CPUTicks(user: 100, system: 50, idle: 800, nice: 10)
    let new = CPUTicks(user: 160, system: 70, idle: 900, nice: 20)
    // Busy 60 + 20 + 10 = 90 of 190.
    #expect(abs(SystemMath.cpuUsage(from: old, to: new) - 90.0 / 190.0) < 1e-9)
}

@Test func cpuUsageIsZeroWhenNoTimePassed() {
    let ticks = CPUTicks(user: 100, system: 50, idle: 800, nice: 10)
    #expect(SystemMath.cpuUsage(from: ticks, to: ticks) == 0)
}

@Test func cpuUsageSurvivesACounterThatWrapped() {
    let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
    let new = CPUTicks(user: 10, system: 0, idle: 20, nice: 0)
    // 20 user ticks across the wrap, 20 idle.
    #expect(abs(SystemMath.cpuUsage(from: old, to: new) - 0.5) < 1e-9)
}

@Test func networkRatesSumInterfacesPerSecond() {
    let old = ["en0": NetworkCounters(received: 1_000, sent: 500), "en1": NetworkCounters(received: 0, sent: 0)]
    let new = [
        "en0": NetworkCounters(received: 5_000, sent: 1_500), "en1": NetworkCounters(received: 2_000, sent: 1_000),
        // New since the last sample: nothing to compare yet.
        "utun0": NetworkCounters(received: 9_000, sent: 9_000),
    ]
    let rates = SystemMath.networkRates(from: old, to: new, seconds: 2)
    #expect(rates.received == 3_000)
    #expect(rates.sent == 1_000)
}

@Test func aNetworkCounterThatWentDownCountsAsNothing() {
    let old = [
        "en0": NetworkCounters(received: 4_000_000_000, sent: 800), "en1": NetworkCounters(received: 100, sent: 100),
    ]
    let new = ["en0": NetworkCounters(received: 1_000, sent: 1_800), "en1": NetworkCounters(received: 300, sent: 100)]
    let rates = SystemMath.networkRates(from: old, to: new, seconds: 1)
    #expect(rates.received == 200)
    #expect(rates.sent == 1_000)
    #expect(SystemMath.delta(from: 10, to: 3) == 0)
}

@Test func networkRatesAreZeroWithoutElapsedTime() {
    let counters = ["en0": NetworkCounters(received: 1, sent: 1)]
    let rates = SystemMath.networkRates(from: [:], to: counters, seconds: 0)
    #expect(rates.received == 0 && rates.sent == 0)
}

@Test func memoryUsedIsAppMemoryWiredAndCompressed() {
    let used = SystemMath.memoryUsed(
        internalPages: 1_000, purgeablePages: 200, wiredPages: 300, compressedPages: 100, pageSize: 16_384)
    #expect(used == (800 + 300 + 100) * 16_384)
    // More purgeable than internal pages leaves no app memory, not an underflow.
    #expect(
        SystemMath.memoryUsed(internalPages: 10, purgeablePages: 20, wiredPages: 1, compressedPages: 0, pageSize: 4_096)
            == 4_096)
}

@Test func parsesPsOutputWithSpacesInNamesAndSkipsBadLines() {
    let output = """
            1   0.0  12345 launchd
          654  12.5 204800 Google Chrome Helper (Renderer)
          bad line
        77 x 10 name
          88   1.0
          99   3.25    512   Code Helper
        """
    let processes = SystemMath.parseProcesses(output)
    #expect(
        processes == [
            ProcessUsage(pid: 1, cpu: 0, memory: 12_345 * 1024, name: "launchd"),
            ProcessUsage(pid: 654, cpu: 12.5, memory: 204_800 * 1024, name: "Google Chrome Helper (Renderer)"),
            ProcessUsage(pid: 99, cpu: 3.25, memory: 512 * 1024, name: "Code Helper"),
        ])
}

@Test func topProcessesAreTheTenBusiestOrLargest() {
    let processes = (1...15).map {
        ProcessUsage(pid: Int32($0), cpu: Double($0), memory: UInt64(100 - $0), name: "p\($0)")
    }
    let byCPU = SystemMath.top(processes, by: .cpu)
    #expect(byCPU.map(\.pid) == Array((6...15).reversed()))
    let byMemory = SystemMath.top(processes, by: .memory)
    #expect(byMemory.map(\.pid) == Array(1...10))
}

@Test func topProcessesBreakTiesByTheOtherFigureThenPid() {
    let processes = [
        ProcessUsage(pid: 3, cpu: 1, memory: 10, name: "c"),
        ProcessUsage(pid: 2, cpu: 1, memory: 20, name: "b"),
        ProcessUsage(pid: 1, cpu: 1, memory: 10, name: "a"),
    ]
    #expect(SystemMath.top(processes, by: .cpu).map(\.pid) == [2, 1, 3])
}

@Test func usageLevelsTurnAt75And90Percent() {
    #expect(UsageLevel(0) == .normal)
    #expect(UsageLevel(0.75) == .normal)
    #expect(UsageLevel(0.76) == .warning)
    #expect(UsageLevel(0.9) == .warning)
    #expect(UsageLevel(0.91) == .critical)
    #expect(UsageLevel(1) == .critical)
}

@Test func readsTheInternalBatteryAndIgnoresOtherSources() {
    let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]
    let battery: [String: Any] = [
        kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 43, kIOPSMaxCapacityKey: 100,
        kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSTimeToEmptyKey: 342,
    ]
    #expect(
        SystemMath.battery(from: [ups, battery]) == BatteryStatus(charge: 0.43, state: .onBattery, minutesLeft: 342))
    var charging = battery
    charging[kIOPSIsChargingKey] = true
    charging[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
    #expect(SystemMath.battery(from: [charging])?.state == .charging)
    #expect(SystemMath.battery(from: [charging])?.minutesLeft == nil)
    var unknown = battery
    unknown[kIOPSTimeToEmptyKey] = -1
    #expect(SystemMath.battery(from: [unknown])?.minutesLeft == nil)
    #expect(SystemMath.battery(from: [ups]) == nil)
}

@MainActor @Test func theModelWorksOutRatesAndKeepsTwoMinutesOfHistory() {
    let model = SystemModel { SystemReadout(time: 0) }
    func readout(_ step: Int) -> SystemReadout {
        SystemReadout(
            time: Double(step) * 2, cpu: CPUTicks(user: UInt32(step * 10), system: 0, idle: UInt32(step * 30), nice: 0),
            memory: MemoryUsage(used: UInt64(step), total: 100, swapUsed: 0),
            network: ["en0": NetworkCounters(received: UInt64(step) * 2_000, sent: UInt64(step) * 200)])
    }
    model.apply(readout(0))
    #expect(model.cpuUsage == nil)
    #expect(model.history.isEmpty)
    model.apply(readout(1))
    #expect(model.cpuUsage == 0.25)
    #expect(model.downloadRate == 1_000)
    #expect(model.uploadRate == 100)
    #expect(model.history.count == 1)
    for step in 2...70 { model.apply(readout(step)) }
    #expect(model.history.count == SystemModel.historyLength)
    #expect(model.history.last?.memoryUsed == 70)
    #expect(model.history.first?.memoryUsed == 11)
}
