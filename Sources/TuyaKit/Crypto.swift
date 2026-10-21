import CommonCrypto
import CryptoKit
import Foundation

/// Small crypto helpers for the Tuya LAN protocol.
enum TuyaCrypto {
    /// Key Tuya devices use to encrypt their LAN broadcasts: MD5("yGAdlopoPVldABfn").
    static let udpKey = Data(Insecure.MD5.hash(data: Data("yGAdlopoPVldABfn".utf8)))

    // MARK: AES-128-ECB (v3.3 / v3.4)

    static func ecbEncrypt(_ data: Data, key: Data, pad: Bool = true) throws -> Data {
        try ecb(data, key: key, op: CCOperation(kCCEncrypt), pad: pad)
    }

    static func ecbDecrypt(_ data: Data, key: Data, pad: Bool = true) throws -> Data {
        try ecb(data, key: key, op: CCOperation(kCCDecrypt), pad: pad)
    }

    private static func ecb(_ data: Data, key: Data, op: CCOperation, pad: Bool) throws -> Data {
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let options = CCOptions(kCCOptionECBMode) | (pad ? CCOptions(kCCOptionPKCS7Padding) : 0)
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, k.baseAddress, key.count, nil,
                            d.baseAddress, data.count, o.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw TuyaError.crypto }
        return out.prefix(moved)
    }

    // MARK: AES-128-GCM (v3.5)

    static func gcmSeal(_ plain: Data, key: Data, iv: Data, aad: Data) throws -> (ciphertext: Data, tag: Data) {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
        return (box.ciphertext, box.tag)
    }

    static func gcmOpen(_ ciphertext: Data, key: Data, iv: Data, tag: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    // MARK: Hashes

    static func hmacSHA256(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func random(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }
}

public enum TuyaError: LocalizedError, Equatable {
    case crypto
    case badFrame(String)
    case handshake(String)
    case unreachable(String)
    case timeout
    case noKey(String)
    case unsupportedVersion(String)
    case device(String)

    public var errorDescription: String? {
        switch self {
        case .crypto: return "Encryption failed. Is the local key right?"
        case .badFrame(let s): return "The device sent something unexpected (\(s))."
        case .handshake(let s): return "Couldn't set up a session with the device (\(s)). The local key may be wrong."
        case .unreachable(let s): return "Couldn't reach the device: \(s)"
        case .timeout: return "The device didn't answer in time."
        case .noKey(let name): return "No local key saved for \(name)."
        case .unsupportedVersion(let v): return "Tuya protocol \(v) isn't supported yet."
        case .device(let s): return s
        }
    }
}

extension Data {
    init?(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    func uint32(at offset: Int) -> UInt32 {
        let s = startIndex + offset
        return self[s..<s + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
