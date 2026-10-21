import XCTest
@testable import TuyaKit

/// Encodings must match tuya-convert's reference implementation exactly.
final class SmartConfigTests: XCTestCase {
    func testBroadcastBody() {
        XCTAssertEqual(SmartConfig.broadcastBody(password: "pa$$word12", ssid: "HomeWiFi", tokenGroup: "AYabcdefgh1234"), V.scBroadcast)
    }

    func testMulticastBody() {
        XCTAssertEqual(SmartConfig.multicastBody(password: "pa$$word12", ssid: "HomeWiFi", tokenGroup: "AYabcdefgh1234"), V.scMulticast)
    }

    func testMulticastHead() {
        XCTAssertEqual(SmartConfig.multicastHead, V.scHeadMulticast)
    }
}
