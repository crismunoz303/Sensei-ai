import Foundation
import CryptoKit

enum BitcoinHasher {
    static func doubleSHA256(_ data: Data) -> Data {
        let first = Data(SHA256.hash(data: data))
        return Data(SHA256.hash(data: first))
    }

    static func headerWithNonce(prefix76: Data, nonce: UInt32) -> Data {
        precondition(prefix76.count == 76)
        var result = prefix76
        var littleEndianNonce = nonce.littleEndian
        withUnsafeBytes(of: &littleEndianNonce) { result.append(contentsOf: $0) }
        return result
    }

    static func hashHeader(prefix76: Data, nonce: UInt32) -> Data {
        doubleSHA256(headerWithNonce(prefix76: prefix76, nonce: nonce))
    }

    static func selfTest() -> Bool {
        let empty = Data()
        let expected = "5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456"
        return doubleSHA256(empty).hexString == expected
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
