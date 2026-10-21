import Darwin
import Foundation

/// Tuya EZ-mode ("SmartConfig") Wi-Fi provisioning.
///
/// Port of tuya-convert's smartconfig (kueblc, MIT; broadcast strategy from tuyapi/link). A device
/// in pairing mode (light blinking fast) sniffs Wi-Fi traffic; the SSID, password and a cloud
/// pairing token are encoded two ways at once:
///  - broadcast: the *lengths* of UDP packets sent to 255.255.255.255:30011
///  - multicast: the *addresses* 226.x.y.z:30012 (password AES-encrypted)
public enum SmartConfig {
    static let broadcastHead = [1, 3, 6, 10]
    static let multicastKey = Data("a3c6794oiu876t54".utf8)
    static var multicastHead: [String] { ips(Array("TYST01".utf8).map(Int.init), sequence: 120) }

    static func crc8(_ data: [Int]) -> Int {
        var r = 0
        for var b in data {
            b ^= r
            r = 0
            for _ in 0..<8 {
                if (r ^ b) & 1 != 0 { r ^= 0x18; r >>= 1; r |= 0x80 } else { r >>= 1 }
                b >>= 1
            }
        }
        return r
    }

    static func broadcastBody(password: String, ssid: String, tokenGroup: String) -> [Int] {
        let r = [password.utf8.count] + password.utf8.map(Int.init) + [tokenGroup.utf8.count]
            + tokenGroup.utf8.map(Int.init) + ssid.utf8.map(Int.init)
        let length = r.count, lengthCRC = crc8([length])
        var e = [length >> 4 | 16, length & 0xF | 32, lengthCRC >> 4 | 48, lengthCRC & 0xF | 64]
        var sequence = 0, i = 0
        while i < length {
            let chunk = Array(r[i..<min(i + 4, length)])
            var group = [sequence] + chunk
            group += Array(repeating: 0, count: 5 - group.count)
            e.append(crc8(group) & 0x7F | 128)
            e.append(sequence | 128)
            e += chunk.map { $0 | 256 }
            sequence += 1
            i += 4
        }
        e += Array(repeating: 256, count: length - (i - 4))  // as in the reference implementation
        return e
    }

    static func multicastBody(password: String, ssid: String, tokenGroup: String) -> [String] {
        func withHeader(_ raw: [UInt8], _ payload: [UInt8]) -> [Int] {
            let crc = TuyaCrypto.crc32(Data(raw))
            return [raw.count, raw.count, Int(crc & 0xFF), Int(crc >> 8 & 0xFF), Int(crc >> 16 & 0xFF), Int(crc >> 24 & 0xFF)]
                + payload.map(Int.init)
        }
        let s = Array(ssid.utf8), p = Array(password.utf8), t = Array(tokenGroup.utf8)
        var padded = Data(p)
        padded.append(Data(count: (16 - p.count % 16) % 16))
        let enc = (try? TuyaCrypto.ecbEncrypt(padded, key: multicastKey, pad: false)) ?? Data()
        return ips(withHeader(s, s), sequence: 64) + ips(withHeader(p, Array(enc)), sequence: 0) + ips(withHeader(t, t), sequence: 32)
    }

    static func ips(_ data: [Int], sequence start: Int) -> [String] {
        var d = data
        if d.count % 2 == 1 { d.append(0) }
        return stride(from: 0, to: d.count, by: 2).enumerated().map { n, i in "226.\(start + n).\(d[i + 1]).\(d[i])" }
    }

    /// Sends the configuration repeatedly until `shouldStop` returns true.
    public static func transmit(ssid: String, password: String, tokenGroup: String, bindIP: String?,
                                shouldStop: @escaping @Sendable () -> Bool) {
        let bBody = broadcastBody(password: password, ssid: ssid, tokenGroup: tokenGroup)
        let mBody = multicastBody(password: password, ssid: ssid, tokenGroup: tokenGroup)
        let mHead = multicastHead
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1, ttl: UInt8 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        if let bindIP {
            var iface = in_addr()
            inet_pton(AF_INET, bindIP, &iface)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
        }
        let zeros = [UInt8](repeating: 0, count: 600)

        func send(to ip: String, port: UInt16, length: Int) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port.bigEndian)
            inet_pton(AF_INET, ip, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, zeros, length, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            usleep(5000)
        }
        func broadcast(_ lengths: [Int]) { lengths.forEach { send(to: "255.255.255.255", port: 30011, length: $0) } }
        func multicast(_ ips: [String]) { ips.forEach { send(to: $0, port: 30012, length: 1) } }

        while !shouldStop() {
            for _ in 0..<40 where !shouldStop() { multicast(mHead); broadcast(broadcastHead) }
            for _ in 0..<10 where !shouldStop() { multicast(mHead); multicast(mBody); broadcast(bBody) }
        }
    }
}
