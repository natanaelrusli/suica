import IOKit

/// Reads actual fan speeds from AppleSMC. An empty result means the Mac reports zero fans.
enum SMCFanReader {
    // AppleSMC's 80-byte request layout, including C struct padding.
    private static let messageSize = 80
    private static let keyInfoOffset = 28
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let payloadOffset = 48

    static func read() -> [Int]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        guard let count = key("FNum", connection: connection), count.type == fourCC("ui8 "),
            count.bytes.count == 1, count.bytes[0] <= 10
        else { return nil }

        var speeds: [Int] = []
        for fan in 0..<Int(count.bytes[0]) {
            guard let value = key("F\(fan)Ac", connection: connection),
                let rpm = decodeRPM(type: value.type, bytes: value.bytes)
            else { return nil }
            speeds.append(rpm)
        }
        return speeds
    }

    static func decodeRPM(type: UInt32, bytes: [UInt8]) -> Int? {
        switch (type, bytes.count) {
        case (fourCC("flt "), 4):
            let bits = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            let rpm = Double(Float(bitPattern: bits)).rounded()
            guard rpm >= 0 else { return nil }
            return Int(exactly: rpm)
        case (fourCC("fpe2"), 2):
            let fixedPoint = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Int((Double(fixedPoint) / 4).rounded())
        default:
            return nil
        }
    }

    private static func key(_ name: String, connection: io_connect_t) -> (type: UInt32, bytes: [UInt8])? {
        var request = [UInt8](repeating: 0, count: messageSize)
        request.withUnsafeMutableBytes { $0.storeBytes(of: fourCC(name), as: UInt32.self) }
        request[commandOffset] = 9 // Read key metadata.
        guard let metadata = call(connection, request) else { return nil }
        let (size, type) = metadata.withUnsafeBytes {
            ($0.loadUnaligned(fromByteOffset: keyInfoOffset, as: UInt32.self),
             $0.loadUnaligned(fromByteOffset: keyInfoOffset + 4, as: UInt32.self))
        }
        guard size > 0, size <= messageSize - payloadOffset else { return nil }
        request[keyInfoOffset..<resultOffset] = metadata[keyInfoOffset..<resultOffset]
        request[commandOffset] = 5 // Read the key's value.
        guard let value = call(connection, request) else { return nil }
        return (type, Array(value[payloadOffset..<(payloadOffset + Int(size))]))
    }

    private static func call(_ connection: io_connect_t, _ request: [UInt8]) -> [UInt8]? {
        var response = [UInt8](repeating: 0, count: messageSize)
        var size = messageSize
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &size)
            }
        }
        return result == KERN_SUCCESS && size == messageSize && response[resultOffset] == 0 ? response : nil
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
