import XCTest
@testable import TuyaKit

/// Byte-for-byte checks against frames produced by tinytuya with the same key and nonce.
final class ProtocolTests: XCTestCase {
    let key = Data("0123456789abcdef".utf8)
    let iv = Data((1...12).map { UInt8($0) })

    func testV35QueryFrame() throws {
        let f = try FrameCodec.encode(cmd: 16, payload: Data("{}".utf8), seq: 1, version: .v35, key: key, iv: iv)
        XCTAssertEqual(f.hex, V.v35QueryFrame)
    }

    func testV35ControlFrameAddsVersionHeader() throws {
        let f = try FrameCodec.encode(cmd: 13, payload: Data(V.v35ControlPayload.utf8), seq: 2, version: .v35, key: key, iv: iv)
        XCTAssertEqual(f.hex, V.v35ControlFrame)
    }

    func testV35ReplyDecodes() throws {
        let frame = try FrameCodec.decode(Data(hex: V.v35ReplyFrame)!, version: .v35, key: key)
        XCTAssertEqual(frame.cmd, 16)
        XCTAssertEqual(frame.retcode, 0)
        let dps = try XCTUnwrap(TuyaLocal.dataPoints(frame.payload))
        XCTAssertEqual(dps["20"] as? Bool, true)
        XCTAssertEqual(dps["22"] as? Int, 500)
    }

    func testWrongKeyIsRejected() {
        XCTAssertThrowsError(try FrameCodec.decode(Data(hex: V.v35ReplyFrame)!, version: .v35, key: Data("ffffffffffffffff".utf8)))
    }

    func testSessionKeys() throws {
        let local = Data((0..<16).map { UInt8($0) }), remote = Data((16..<32).map { UInt8($0) })
        XCTAssertEqual(try Session.sessionKey(localNonce: local, remoteNonce: remote, localKey: key, version: .v35).hex, V.v35SessionKey)
        XCTAssertEqual(try Session.sessionKey(localNonce: local, remoteNonce: remote, localKey: key, version: .v34).hex, V.v34SessionKey)
    }

    func testHandshakeReplyCarriesNonceAndHMAC() throws {
        let local = Data((0..<16).map { UInt8($0) })
        let frame = try FrameCodec.decode(Data(hex: V.v35Step2Frame)!, version: .v35, key: key)
        XCTAssertEqual(frame.cmd, 4)
        XCTAssertEqual(frame.payload.count, 48)
        XCTAssertEqual(frame.payload.prefix(16), Data((16..<32).map { UInt8($0) }))
        XCTAssertEqual(frame.payload.suffix(32), TuyaCrypto.hmacSHA256(local, key: key))
        XCTAssertEqual(TuyaCrypto.hmacSHA256(local, key: key).hex, V.hmacLocalNonce)
    }

    func testV33Frames() throws {
        XCTAssertEqual(try FrameCodec.encode(cmd: 10, payload: Data(V.v33QueryPayload.utf8), seq: 1, version: .v33, key: key).hex, V.v33QueryFrame)
        XCTAssertEqual(try FrameCodec.encode(cmd: 7, payload: Data(V.v33ControlPayload.utf8), seq: 2, version: .v33, key: key).hex, V.v33ControlFrame)
        let reply = try FrameCodec.decode(Data(hex: V.v33ReplyFrame)!, version: .v33, key: key)
        XCTAssertEqual(TuyaLocal.dataPoints(reply.payload)?["9"] as? Int, 0)
    }

    func testV34ControlFrame() throws {
        let sk = Data(hex: V.v34SessionKey)!
        XCTAssertEqual(try FrameCodec.encode(cmd: 13, payload: Data(V.v35ControlPayload.utf8), seq: 3, version: .v34, key: sk).hex,
                       V.v34ControlFrame)
    }

    func testLANBroadcasts() throws {
        let b35 = try XCTUnwrap(TuyaDiscovery.parse(Data(hex: V.udp6699Frame)!))
        XCTAssertEqual(b35.id, "bf0123456789abcdef")
        XCTAssertEqual(b35.ip, "10.0.0.5")
        XCTAssertEqual(b35.version, "3.5")
        let b33 = try XCTUnwrap(TuyaDiscovery.parse(Data(hex: V.udp55aaFrame)!))
        XCTAssertEqual(b33.version, "3.3")
    }

    func testFrameLengthNeedsWholeHeader() throws {
        let f = Data(hex: V.v35QueryFrame)!
        XCTAssertNil(try FrameCodec.totalLength(f.prefix(10)))
        XCTAssertEqual(try FrameCodec.totalLength(f), f.count)
        XCTAssertEqual(TCPLink.prefixOffset(in: Data([9, 9]) + f), 2)
    }
}
