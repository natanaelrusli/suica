import Darwin
import Foundation
import IOKit.ps

// MARK: - Readings

/// CPU time since boot in ticks, summed over every core. The counters are 32-bit and wrap.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Activity Monitor's "Memory Used" and the swap in use, in bytes.
public struct MemoryUsage: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64
    public var swapUsed: UInt64

    public init(used: UInt64, total: UInt64, swapUsed: UInt64) {
        self.used = used
        self.total = total
        self.swapUsed = swapUsed
    }
}

/// The start-up volume, counting free space as Finder does ("available for important usage").
public struct DiskUsage: Equatable, Sendable {
    public var total: UInt64
    public var available: UInt64

    public init(total: UInt64, available: UInt64) {
        self.total = total
        self.available = available
    }

    public var used: UInt64 { total > available ? total - available : 0 }
}

/// Bytes an interface has received and sent since it came up. The counters are 32-bit and wrap.
public struct NetworkCounters: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

public enum PowerState: Equatable, Sendable {
    case charging
    /// On the power adapter but not charging: full, or held back by optimised charging.
    case pluggedIn
    case onBattery
}

public struct BatteryStatus: Equatable, Sendable {
    /// 0 to 1.
    public var charge: Double
    public var state: PowerState
    /// Minutes until empty while on battery, when macOS has worked it out.
    public var minutesLeft: Int?

    public init(charge: Double, state: PowerState, minutesLeft: Int?) {
        self.charge = charge
        self.state = state
        self.minutesLeft = minutesLeft
    }
}

/// macOS's thermal state, from nominal (cool) to critical (throttled hard).
public enum ThermalLevel: Equatable, Sendable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// One process as `ps` reports it.
public struct ProcessUsage: Identifiable, Equatable, Sendable {
    public var pid: Int32
    /// Percent of one core, so a busy process can go past 100.
    public var cpu: Double
    /// Resident memory in bytes.
    public var memory: UInt64
    public var name: String

    public var id: Int32 { pid }

    public init(pid: Int32, cpu: Double, memory: UInt64, name: String) {
        self.pid = pid
        self.cpu = cpu
        self.memory = memory
        self.name = name
    }
}

public enum ProcessOrder: Hashable, Sendable, CaseIterable {
    case cpu, memory
}

/// How full a bar or line is: orange above 75 %, red above 90 %.
public enum UsageLevel: Equatable, Sendable {
    case normal, warning, critical

    public init(_ fraction: Double) {
        self = fraction > 0.9 ? .critical : fraction > 0.75 ? .warning : .normal
    }
}

/// Everything the page reads in one sample.
public struct SystemReadout: Sendable {
    /// Seconds on a clock that only goes forward, for the rates.
    public var time: TimeInterval
    public var cpu: CPUTicks?
    /// Over 1, 5 and 15 minutes.
    public var loadAverages: [Double]
    public var cores: Int
    public var memory: MemoryUsage?
    public var disk: DiskUsage?
    /// By interface name, loopback left out.
    public var network: [String: NetworkCounters]
    /// Nil on a Mac without a battery.
    public var battery: BatteryStatus?
    public var thermal: ThermalLevel
    /// Seconds since boot, sleep included.
    public var uptime: TimeInterval
    public var processes: [ProcessUsage]

    public init(
        time: TimeInterval, cpu: CPUTicks? = nil, loadAverages: [Double] = [], cores: Int = 1,
        memory: MemoryUsage? = nil, disk: DiskUsage? = nil, network: [String: NetworkCounters] = [:],
        battery: BatteryStatus? = nil, thermal: ThermalLevel = .nominal, uptime: TimeInterval = 0,
        processes: [ProcessUsage] = []
    ) {
        self.time = time
        self.cpu = cpu
        self.loadAverages = loadAverages
        self.cores = cores
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.thermal = thermal
        self.uptime = uptime
        self.processes = processes
    }
}

// MARK: - Arithmetic

public enum SystemMath {
    /// The busy share of the CPU between two samples, 0 to 1: user, system and nice time over all
    /// time. Wrapping subtraction keeps a counter that wrapped once right; no time passed gives 0.
    public static func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> Double {
        let busy = Double(new.user &- old.user) + Double(new.system &- old.system) + Double(new.nice &- old.nice)
        let total = busy + Double(new.idle &- old.idle)
        return total > 0 ? min(max(busy / total, 0), 1) : 0
    }

    /// Bytes a counter moved; one that went down (wrapped or reset) counts as nothing.
    public static func delta(from old: UInt64, to new: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    /// Download and upload in bytes per second, summed over the interfaces seen in both samples.
    public static func networkRates(
        from old: [String: NetworkCounters], to new: [String: NetworkCounters], seconds: TimeInterval
    ) -> (received: Double, sent: Double) {
        guard seconds > 0 else { return (0, 0) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counters) in new {
            guard let before = old[name] else { continue }
            received += delta(from: before.received, to: counters.received)
            sent += delta(from: before.sent, to: counters.sent)
        }
        return (Double(received) / seconds, Double(sent) / seconds)
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous pages less purgeable ones), wired
    /// and compressed, in bytes.
    public static func memoryUsed(
        internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64
    ) -> UInt64 {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }

    /// Lines of `ps -Aceo pid=,pcpu=,rss=,comm=`: the PID, CPU %, resident KiB, then the name,
    /// which may hold spaces. Lines that do not read so are skipped.
    public static func parseProcesses(_ output: String) -> [ProcessUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                let kibibytes = UInt64(fields[2])
            else { return nil }
            let name = fields[3].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return ProcessUsage(pid: pid, cpu: cpu, memory: kibibytes * 1024, name: name)
        }
    }

    /// The `count` processes using the most CPU or memory, the other figure breaking ties.
    public static func top(_ processes: [ProcessUsage], by order: ProcessOrder, count: Int = 10) -> [ProcessUsage] {
        let sorted = processes.sorted { a, b in
            switch order {
            case .cpu: (a.cpu, a.memory, b.pid) > (b.cpu, b.memory, a.pid)
            case .memory: (a.memory, a.cpu, b.pid) > (b.memory, b.cpu, a.pid)
            }
        }
        return Array(sorted.prefix(count))
    }

    /// The internal battery among IOKit's power source descriptions, or nil when there is none.
    public static func battery(from descriptions: [[String: Any]]) -> BatteryStatus? {
        for description in descriptions where description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let state: PowerState = charging ? .charging : onAC ? .pluggedIn : .onBattery
            // -1 while macOS is still working it out.
            let minutes = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatteryStatus(
                charge: min(max(Double(current) / Double(maximum), 0), 1), state: state,
                minutesLeft: state == .onBattery ? minutes : nil)
        }
        return nil
    }
}

// MARK: - Reading the Mac

/// Reads this Mac's figures from the kernel, IOKit and `ps`. Each part that fails is left out.
public enum SystemReader {
    private static let host = mach_host_self()

    /// One full sample. `ps` runs off the calling actor.
    @concurrent public static func read() async -> SystemReadout {
        SystemReadout(
            time: ProcessInfo.processInfo.systemUptime, cpu: cpuTicks(), loadAverages: loadAverages(),
            cores: ProcessInfo.processInfo.activeProcessorCount, memory: memory(), disk: disk(),
            network: network(), battery: battery(), thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            uptime: uptime(), processes: await processes())
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(
            user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    static func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let used = SystemMath.memoryUsed(
            internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(pageSize))
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return MemoryUsage(used: used, total: ProcessInfo.processInfo.physicalMemory, swapUsed: swapUsed)
    }

    static func disk() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskUsage(total: UInt64(max(total, 0)), available: UInt64(max(available, 0)))
    }

    static func network() -> [String: NetworkCounters] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [:] }
        defer { freeifaddrs(first) }
        var counters: [String: NetworkCounters] = [:]
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = interface.ifa_data
            else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[String(cString: interface.ifa_name)] = NetworkCounters(
                received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes))
        }
        return counters
    }

    static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return SystemMath.battery(from: descriptions)
    }

    /// From the boot time, so the time asleep counts as `uptime` counts it.
    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let booted = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        return max(Date().timeIntervalSince1970 - booted, 0)
    }

    /// Every process, other users' and root's too, which `ps` may read without extra permissions.
    static func processes() async -> [ProcessUsage] {
        let invocation = Invocation(
            executable: "/bin/ps", arguments: ["-Aceo", "pid=,pcpu=,rss=,comm="],
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"], workingDirectory: "/", timeout: 5)
        guard let result = try? await ProcessRunner().run(invocation), result.exitCode == 0 else { return [] }
        return SystemMath.parseProcesses(String(decoding: result.stdout, as: UTF8.self))
    }
}

// MARK: - Model

/// One point on the page's lines.
public struct SystemSample: Identifiable, Equatable, Sendable {
    public let id: Int
    /// 0 to 1.
    public var cpu: Double
    public var memoryUsed: UInt64?
    /// Bytes per second.
    public var download: Double
    public var upload: Double
}

/// The System page's state: the latest reading, the rates worked out from the one before, and the
/// last two minutes of history, kept in memory while the page is open.
@MainActor @Observable
public final class SystemModel {
    /// Two minutes at one sample every two seconds.
    public static let historyLength = 60

    public private(set) var latest: SystemReadout?
    /// Nil until there are two samples to compare.
    public private(set) var cpuUsage: Double?
    public private(set) var downloadRate: Double?
    public private(set) var uploadRate: Double?
    public private(set) var history: [SystemSample] = []
    public var processOrder: ProcessOrder = .cpu

    @ObservationIgnored private let read: @Sendable () async -> SystemReadout
    @ObservationIgnored private var nextId = 0

    public init(read: @escaping @Sendable () async -> SystemReadout = { await SystemReader.read() }) {
        self.read = read
    }

    public var topProcesses: [ProcessUsage] { SystemMath.top(latest?.processes ?? [], by: processOrder) }

    public func sample() async { apply(await read()) }

    /// Samples until cancelled; the page runs it only while it is on screen.
    public func runSampleLoop(every interval: Duration) async {
        while !Task.isCancelled {
            await sample()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func apply(_ next: SystemReadout) {
        if let previous = latest {
            let cpu = previous.cpu.flatMap { old in next.cpu.map { SystemMath.cpuUsage(from: old, to: $0) } } ?? 0
            let rates = SystemMath.networkRates(
                from: previous.network, to: next.network, seconds: next.time - previous.time)
            cpuUsage = cpu
            downloadRate = rates.received
            uploadRate = rates.sent
            history.append(
                SystemSample(
                    id: nextId, cpu: cpu, memoryUsed: next.memory?.used, download: rates.received, upload: rates.sent))
            nextId += 1
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        latest = next
    }
}
