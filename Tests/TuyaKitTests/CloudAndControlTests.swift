import XCTest
@testable import TuyaKit

final class CloudSigningTests: XCTestCase {
    func testBusinessRequestSignatureMatchesTinyTuya() {
        let h = TuyaCloud.signedHeaders(clientId: "clientid123", secret: "secretABC", token: "tok456", t: "1700000000000",
                                        method: "POST", path: "/v1.0/device/paring/token", body: Data(V.cloudBody.utf8))
        XCTAssertEqual(h["sign"], V.cloudSign)
        XCTAssertEqual(h["access_token"], "tok456")
    }

    func testTokenRequestSignatureMatchesTinyTuya() {
        let h = TuyaCloud.signedHeaders(clientId: "clientid123", secret: "secretABC", token: nil, t: "1700000000000",
                                        method: "GET", path: "/v1.0/token?grant_type=1", body: Data())
        XCTAssertEqual(h["sign"], V.cloudTokenSign)
        XCTAssertNil(h["access_token"])
    }
}

final class LightLogicTests: XCTestCase {
    let bulb = DeviceRecords.fromStatus(id: "b", name: "Bulb", ip: "10.0.0.2", version: "3.5",
                                        dps: ["20": true, "21": "white", "22": 1000, "23": 0, "24": "003403e803e8"])
    let strip = DeviceRecords.fromStatus(id: "s", name: "Strip", ip: "10.0.0.3", version: "3.5",
                                         dps: ["20": true, "21": "colour", "24": "000003e803e8"])

    func testRecordsFromStatus() {
        XCTAssertEqual(bulb.kind, .light)
        XCTAssertTrue(bulb.hasWarmth)
        XCTAssertEqual(strip.kind, .light)
        XCTAssertFalse(strip.hasWarmth)
        XCTAssertTrue(strip.hasBrightness)  // via the colour value
        let board = DeviceRecords.fromStatus(id: "x", name: "Board", ip: "", version: "3.3", dps: ["1": true, "2": false, "9": 0])
        XCTAssertEqual(board.toggles.map(\.dp), ["1", "2"])
    }

    func testStripBrightnessComesFromColourValue() {
        let s = TuyaControl.lightState(strip, ["20": true, "21": "colour", "24": "00e603e80190"])
        XCTAssertEqual(s.hue, 230)
        XCTAssertEqual(s.brightness, 40)
    }

    func testBulbWhiteState() {
        let s = TuyaControl.lightState(bulb, ["20": true, "21": "white", "22": 505, "23": 0])
        XCTAssertEqual(s.brightness, 50)
        XCTAssertEqual(s.warmth, 100)
    }

    func testColourEncodings() {
        XCTAssertEqual(TuyaControl.encode(.v2, h: 230, s: 100, v: 40), "00e603e80190")
        XCTAssertEqual(TuyaControl.encode(.v1, h: 0, s: 100, v: 100), "ff00000000ffff")
        XCTAssertEqual(TuyaControl.parse(.v1, "ff00000000ffff")?.v, 100)
    }
}
