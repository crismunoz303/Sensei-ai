import Foundation

enum BitcoinHasher {
    static func writeNonceLE(_ nonce: UInt32, into header: inout [UInt8]) {
        precondition(header.count == 80)
        header[76] = UInt8(nonce & 0xff)
        header[77] = UInt8((nonce >> 8) & 0xff)
        header[78] = UInt8((nonce >> 16) & 0xff)
        header[79] = UInt8((nonce >> 24) & 0xff)
    }

    static func hashHeader(_ header: [UInt8]) -> [UInt8] {
        precondition(header.count == 80)
        return SHA256Core.doubleHash(header)
    }

    static func leadingZeroBits(_ hash: [UInt8]) -> Int {
        var total = 0

        for byte in hash.reversed() {
            if byte == 0 {
                total += 8
                continue
            }

            total += byte.leadingZeroBitCount
            break
        }

        return total
    }

    static func benchmarkHeader() -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 80)
        header[0] = 0x20
        header[68] = 0xff
        header[69] = 0xff
        header[70] = 0x00
        header[71] = 0x1d
        header[72] = 0xff
        header[73] = 0xff
        header[74] = 0x00
        header[75] = 0x1d
        return header
    }
}
