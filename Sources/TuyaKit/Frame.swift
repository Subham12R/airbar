import Foundation

/// Tuya LAN protocol versions AirBar speaks.
public enum TuyaVersion: String, Codable, Sendable, CaseIterable {
    case v33 = "3.3", v34 = "3.4", v35 = "3.5"

    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        self.init(rawValue: s.count == 1 ? s + ".0" : String(s.prefix(3)))
    }

    var header: Data { Data(rawValue.utf8) + Data(count: 12) }
    var negotiatesSession: Bool { self != .v33 }
}

/// Command numbers on the wire.
enum TuyaCommand: UInt32 {
    case sessionStart = 3, sessionResponse = 4, sessionFinish = 5
    case control = 7, status = 8, heartbeat = 9, dpQuery = 10, controlNew = 13, dpQueryNew = 16, updateDps = 18
    case udpNew = 19

    /// Commands sent without the "3.x" version header.
    static let withoutHeader: Set<UInt32> = [3, 4, 5, 9, 10, 16, 18, 64]
}

struct TuyaFrame: Equatable {
    var seq: UInt32
    var cmd: UInt32
    var retcode: UInt32?
    var payload: Data
}

/// Encodes and decodes Tuya frames: `0x55AA` (v3.3 / v3.4) and `0x6699` (v3.5, AES-GCM).
enum FrameCodec {
    static let prefix55AA: UInt32 = 0x0000_55AA, suffix55AA: UInt32 = 0x0000_AA55
    static let prefix6699: UInt32 = 0x0000_6699, suffix6699: UInt32 = 0x0000_9966

    /// Client → device frame. `key` is the local key (v3.3) or the session key (v3.4 / v3.5).
    static func encode(cmd: UInt32, payload: Data, seq: UInt32, version: TuyaVersion, key: Data, iv: Data? = nil) throws -> Data {
        let withHeader = !TuyaCommand.withoutHeader.contains(cmd)
        switch version {
        case .v35:
            let plain = (withHeader ? version.header : Data()) + payload
            var header = Data()
            header.appendUInt32(prefix6699)
            header.append(contentsOf: [0, 0])
            header.appendUInt32(seq)
            header.appendUInt32(cmd)
            header.appendUInt32(UInt32(12 + plain.count + 16))
            let nonce = iv ?? TuyaCrypto.random(12)
            let (ct, tag) = try TuyaCrypto.gcmSeal(plain, key: key, iv: nonce, aad: header.dropFirst(4))
            var out = header + nonce + ct + tag
            out.appendUInt32(suffix6699)
            return out
        case .v34:
            let enc = try TuyaCrypto.ecbEncrypt((withHeader ? version.header : Data()) + payload, key: key)
            var out = Data()
            out.appendUInt32(prefix55AA)
            out.appendUInt32(seq)
            out.appendUInt32(cmd)
            out.appendUInt32(UInt32(enc.count + 32 + 4))
            out += enc
            out += TuyaCrypto.hmacSHA256(out, key: key)
            out.appendUInt32(suffix55AA)
            return out
        case .v33:
            let enc = try TuyaCrypto.ecbEncrypt(payload, key: key)
            let body = withHeader ? version.header + enc : enc
            var out = Data()
            out.appendUInt32(prefix55AA)
            out.appendUInt32(seq)
            out.appendUInt32(cmd)
            out.appendUInt32(UInt32(body.count + 8))
            out += body
            out.appendUInt32(TuyaCrypto.crc32(out))
            out.appendUInt32(suffix55AA)
            return out
        }
    }

    /// Bytes needed for the whole frame, once the header is available (nil if more header bytes are needed).
    static func totalLength(_ data: Data) throws -> Int? {
        guard data.count >= 4 else { return nil }
        switch data.uint32(at: 0) {
        case prefix6699: return data.count >= 18 ? 18 + Int(data.uint32(at: 14)) + 4 : nil
        case prefix55AA: return data.count >= 16 ? 16 + Int(data.uint32(at: 12)) : nil
        default: throw TuyaError.badFrame("unknown prefix")
        }
    }

    /// Device → client frame, decrypted, with the return code and version header removed.
    /// `hasRetcode`: true for replies to our commands; nil to detect it (LAN broadcasts).
    static func decode(_ data: Data, version: TuyaVersion, key: Data, hasRetcode: Bool? = true) throws -> TuyaFrame {
        let d = Data(data)
        guard let total = try totalLength(d), d.count >= total else { throw TuyaError.badFrame("truncated") }
        let seq: UInt32, cmd: UInt32
        var retcode: UInt32? = nil
        var payload: Data

        if d.uint32(at: 0) == prefix6699 {
            seq = d.uint32(at: 6)
            cmd = d.uint32(at: 10)
            let len = Int(d.uint32(at: 14))
            guard len >= 28 else { throw TuyaError.badFrame("short 6699 frame") }
            let iv = d[18..<30], ctEnd = 18 + len - 16
            do {
                payload = try TuyaCrypto.gcmOpen(d[30..<ctEnd], key: key, iv: iv, tag: d[ctEnd..<(18 + len)], aad: d[4..<18])
            } catch {
                throw TuyaError.handshake("message authentication failed")
            }
            let strip = hasRetcode ?? (payload.count > 4 && payload.first != UInt8(ascii: "{") && payload[payload.startIndex + 4] == UInt8(ascii: "{"))
            if strip && payload.count >= 4 {
                retcode = payload.uint32(at: 0)
                payload = payload.dropFirst(4)
            }
        } else {
            seq = d.uint32(at: 4)
            cmd = d.uint32(at: 8)
            let len = Int(d.uint32(at: 12))
            let trailer = (version == .v34 && key != TuyaCrypto.udpKey) ? 36 : 8
            var start = 16
            if hasRetcode ?? true {
                retcode = d.uint32(at: 16)
                start = 20
            }
            guard 16 + len - trailer >= start else { throw TuyaError.badFrame("short 55AA frame") }
            payload = d[start..<(16 + len - trailer)]
            if payload.first != UInt8(ascii: "{") {
                switch version {
                case .v34 where key != TuyaCrypto.udpKey:
                    payload = try TuyaCrypto.ecbDecrypt(payload, key: key)
                default:
                    payload = stripVersionHeader(payload)
                    if !payload.isEmpty { payload = try TuyaCrypto.ecbDecrypt(payload, key: key) }
                }
            }
        }
        return TuyaFrame(seq: seq, cmd: cmd, retcode: retcode, payload: stripVersionHeader(Data(payload)))
    }

    static func stripVersionHeader(_ p: Data) -> Data {
        guard p.count >= 15, p.first == UInt8(ascii: "3"), p[p.startIndex + 1] == UInt8(ascii: ".") else { return Data(p) }
        return Data(p.dropFirst(15))
    }
}
