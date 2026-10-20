import Foundation

/// A unit a duration setting can be typed in. The agent stores whole numbers of the field's own
/// unit, so only units at least as large as it are offered.
public enum DurationUnit: String, CaseIterable, Sendable {
    case seconds, minutes, hours, days

    public var seconds: Int {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        case .days: 86400
        }
    }

    /// `seconds`, `minutes` or `hours` as the agent names them; nil for any other unit.
    public init?(fieldUnit: String?) {
        guard let fieldUnit, let unit = DurationUnit(rawValue: fieldUnit), unit != .days else { return nil }
        self = unit
    }

    /// The units a field stored in `base` can be typed in.
    public static func offered(for base: DurationUnit) -> [DurationUnit] {
        allCases.filter { $0.seconds >= base.seconds }
    }

    /// The largest offered unit that shows `value` (in `base`) as a whole number: 120 s is 2 min.
    public static func best(for value: Int, base: DurationUnit) -> DurationUnit {
        let total = value * base.seconds
        return offered(for: base).last { total % $0.seconds == 0 && total >= $0.seconds } ?? base
    }

    /// `count` of this unit in `base`.
    public func converted(_ count: Int, to base: DurationUnit) -> Int {
        count * seconds / base.seconds
    }
}

public enum ConfigInputs {
    /// What a host box keeps from pasted text: `https://repo.example/group` is `repo.example`.
    public static func host(from text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespaces)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if let slash = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<slash])
        }
        return host
    }

    /// Minutes after midnight of a 24-hour `HH:MM`; nil for anything else.
    public static func minutes(ofClock text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let hours = Int(parts[0]), let minutes = Int(parts[1]), hours < 24, minutes < 60
        else { return nil }
        return hours * 60 + minutes
    }

    /// `HH:MM` for minutes after midnight.
    public static func clock(fromMinutes minutes: Int) -> String {
        let wrapped = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }
}
