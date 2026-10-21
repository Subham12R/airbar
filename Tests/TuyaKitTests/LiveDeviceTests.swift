import XCTest
@testable import TuyaKit

/// Talks to a real device. Skipped unless these are set:
///   TUYA_TEST_ID, TUYA_TEST_IP, TUYA_TEST_KEY, TUYA_TEST_VERSION (default 3.5)
/// TUYA_TEST_WRITE=1 also re-sends the device's current on/off value (no visible change).
final class LiveDeviceTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func device() throws -> (id: String, ip: String, key: String, version: TuyaVersion) {
        guard let id = env["TUYA_TEST_ID"], let ip = env["TUYA_TEST_IP"], let key = env["TUYA_TEST_KEY"] else {
            throw XCTSkip("set TUYA_TEST_ID / TUYA_TEST_IP / TUYA_TEST_KEY to run against a real device")
        }
        return (id, ip, key, TuyaVersion(string: env["TUYA_TEST_VERSION"] ?? "3.5") ?? .v35)
    }

    func testStatus() async throws {
        let d = try device()
        let dps = try await TuyaLocal.status(id: d.id, ip: d.ip, version: d.version, key: d.key)
        XCTAssertFalse(dps.isEmpty)
        print("LIVE status keys:", dps.keys.sorted())
    }

    func testRewriteCurrentPower() async throws {
        let d = try device()
        guard env["TUYA_TEST_WRITE"] == "1" else { throw XCTSkip("set TUYA_TEST_WRITE=1") }
        let dps = try await TuyaLocal.status(id: d.id, ip: d.ip, version: d.version, key: d.key)
        let dp = dps["20"] != nil ? "20" : "1"
        let current = try XCTUnwrap(dps[dp] as? Bool)
        try await TuyaLocal.set(id: d.id, ip: d.ip, version: d.version, key: d.key, dps: [dp: current])
        let after = try await TuyaLocal.status(id: d.id, ip: d.ip, version: d.version, key: d.key)
        XCTAssertEqual(after[dp] as? Bool, current)
    }

    func testDiscoveryHearsDevice() async throws {
        let d = try device()
        let found = await TuyaDiscovery.scan(seconds: 8)
        XCTAssertTrue(found.contains { $0.id == d.id }, "heard: \(found.map(\.id))")
    }
}
