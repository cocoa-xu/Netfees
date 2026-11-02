import Darwin
import Foundation
import NetFeesCore

enum NetworkCounters {
    static func read() throws -> [String: InterfaceCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return data.withUnsafeBytes { bytes in
                var result: [String: InterfaceCounter] = [:]
                var offset = 0
                while offset + 4 <= size {
                    let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    guard length >= 4, offset + length <= size else { break }
                    let type = bytes[offset + 3]
                    if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                        let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                        if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            // Count the physical path once, including VPN transport on en*.
                            if name.hasPrefix("en"), name.dropFirst(2).allSatisfy(\.isNumber),
                               message.ifm_flags & IFF_LOOPBACK == 0 {
                                result[name] = InterfaceCounter(index: message.ifm_index,
                                    received: message.ifm_data.ifi_ibytes,
                                    sent: message.ifm_data.ifi_obytes)
                            }
                        }
                    }
                    offset += length
                }
                return result
            }
        }
        throw POSIXError(.ENOMEM)
    }
}
