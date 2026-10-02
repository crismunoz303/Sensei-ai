import Foundation

enum HexCodec {
    static func bytes(_ hex: String) -> [UInt8]? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(clean.count / 2)

        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let value = UInt8(clean[index..<next], radix: 16) else {
                return nil
            }
            output.append(value)
            index = next
        }
        return output
    }

    static func reverseWord(_ hex: String) -> [UInt8]? {
        guard let bytes = bytes(hex), bytes.count == 4 else { return nil }
        return Array(bytes.reversed())
    }

    static func swap32BitWords(_ hex: String) -> [UInt8]? {
        guard let bytes = bytes(hex), bytes.count % 4 == 0 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        for start in stride(from: 0, to: bytes.count, by: 4) {
            output.append(contentsOf: bytes[start..<(start + 4)].reversed())
        }
        return output
    }

    static func fixedLittleEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
        guard byteCount > 0 else { return [] }
        var output = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<Swift.min(byteCount, 8) {
            output[index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
        return output
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct PreparedStratumWork: Sendable {
    let job: StratumJob
    let extraNonce2: String
    let headerPrefix: [UInt8]
    let shareTarget: Double
    let networkTarget: Double
}

enum StratumWorkBuilder {
    static func prepare(
        job: StratumJob,
        extraNonce1: String,
        extraNonce2Size: Int,
        difficulty: Double,
        extraNonce2Counter: UInt64
    ) throws -> PreparedStratumWork {
        guard difficulty > 0, difficulty.isFinite else {
            throw WorkError.invalidDifficulty
        }
        guard extraNonce2Size > 0 && extraNonce2Size <= 8 else {
            throw WorkError.unsupportedExtraNonce2Size
        }

        guard
            let coinbase1 = HexCodec.bytes(job.coinbase1),
            let extraNonce1Bytes = HexCodec.bytes(extraNonce1),
            let coinbase2 = HexCodec.bytes(job.coinbase2)
        else {
            throw WorkError.invalidHex
        }

        let extraNonce2Bytes = HexCodec.fixedLittleEndian(
            extraNonce2Counter,
            byteCount: extraNonce2Size
        )
        let extraNonce2Hex = HexCodec.hex(extraNonce2Bytes)

        var coinbase = coinbase1
        coinbase.append(contentsOf: extraNonce1Bytes)
        coinbase.append(contentsOf: extraNonce2Bytes)
        coinbase.append(contentsOf: coinbase2)

        var merkleRoot = SHA256Core.doubleHash(coinbase)

        for branchHex in job.merkleBranches {
            guard let branch = HexCodec.bytes(branchHex), branch.count == 32 else {
                throw WorkError.invalidMerkleBranch
            }
            merkleRoot = SHA256Core.doubleHash(merkleRoot + branch)
        }

        guard
            let version = HexCodec.reverseWord(job.version),
            let prevHash = HexCodec.swap32BitWords(job.prevHash),
            let ntime = HexCodec.reverseWord(job.ntime),
            let nbits = HexCodec.reverseWord(job.nbits)
        else {
            throw WorkError.invalidHeaderField
        }

        guard prevHash.count == 32, merkleRoot.count == 32 else {
            throw WorkError.invalidHeaderField
        }

        var prefix: [UInt8] = []
        prefix.reserveCapacity(76)
        prefix.append(contentsOf: version)
        prefix.append(contentsOf: prevHash)
        prefix.append(contentsOf: merkleRoot)
        prefix.append(contentsOf: ntime)
        prefix.append(contentsOf: nbits)

        guard prefix.count == 76 else {
            throw WorkError.invalidHeaderLength
        }

        return PreparedStratumWork(
            job: job,
            extraNonce2: extraNonce2Hex,
            headerPrefix: prefix,
            shareTarget: shareTarget(forDifficulty: difficulty),
            networkTarget: compactTarget(job.nbits)
        )
    }

    static func header(_ work: PreparedStratumWork, nonce: UInt32) -> [UInt8] {
        var header = work.headerPrefix
        header.append(UInt8(nonce & 0xff))
        header.append(UInt8((nonce >> 8) & 0xff))
        header.append(UInt8((nonce >> 16) & 0xff))
        header.append(UInt8((nonce >> 24) & 0xff))
        return header
    }

    static func numericHashValue(_ digest: [UInt8]) -> Double {
        var value = 0.0
        for byte in digest.reversed() {
            value = value * 256.0 + Double(byte)
        }
        return value
    }

    static func shareTarget(forDifficulty difficulty: Double) -> Double {
        let diff1 = Double(0xffff0000) * pow(2.0, 192.0)
        return diff1 / difficulty
    }

    static func compactTarget(_ nbitsHex: String) -> Double {
        guard let compact = UInt32(nbitsHex, radix: 16) else {
            return 0
        }
        let exponent = Int((compact >> 24) & 0xff)
        let mantissa = Double(compact & 0x007fffff)
        return mantissa * pow(256.0, Double(exponent - 3))
    }

    enum WorkError: LocalizedError {
        case invalidDifficulty
        case unsupportedExtraNonce2Size
        case invalidHex
        case invalidMerkleBranch
        case invalidHeaderField
        case invalidHeaderLength

        var errorDescription: String? {
            switch self {
            case .invalidDifficulty:
                return "Pool supplied an invalid difficulty"
            case .unsupportedExtraNonce2Size:
                return "Pool extranonce2 size is unsupported"
            case .invalidHex:
                return "Pool job contains invalid hexadecimal data"
            case .invalidMerkleBranch:
                return "Pool job contains an invalid merkle branch"
            case .invalidHeaderField:
                return "Pool job contains an invalid block-header field"
            case .invalidHeaderLength:
                return "Constructed Bitcoin header prefix is not 76 bytes"
            }
        }
    }
}
