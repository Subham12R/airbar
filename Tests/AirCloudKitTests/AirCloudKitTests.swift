import XCTest
@testable import AirCloudKit

/// Shaped like a real `rac/model-wise/rac-configuration` entry for a cooling-only wall split.
let coolingOnlyModel: [String: Any] = [
    "cloudId": "190_EXAMPLE.MODEL",
    "swing": ["VERTICAL": true, "HORIZONTAL": false],
    "racOperationModes": [
        ["mode": "COOLING", "minTemperature": 16.0, "maxTemperature": 32.0, "temperatureSettingPitchType": 0.5,
         "defaultHumidity": 0.0, "enableSettings": ["temperature": true, "humidity": false, "fan": true, "swing": true],
         "enableFanSpeed": ["AUTO": true, "LV1": true, "LV2": true, "LV3": true, "LV4": true, "LV5": true],
         "defaultFanSpeed": ["AUTO": true]],
        ["mode": "FAN", "minTemperature": 0.0, "maxTemperature": 0.0, "temperatureSettingPitchType": 1.0,
         "enableSettings": ["temperature": false, "humidity": false],
         "enableFanSpeed": ["AUTO": false, "LV1": true, "LV2": true, "LV3": true, "LV4": true, "LV5": true],
         "defaultFanSpeed": ["LV2": true]],
        ["mode": "DRY", "minTemperature": 16.0, "maxTemperature": 32.0, "temperatureSettingPitchType": 0.5,
         "enableSettings": ["temperature": true, "humidity": false],
         "enableFanSpeed": ["AUTO": true, "LV1": true, "LV2": true], "defaultFanSpeed": ["AUTO": true]],
        ["mode": "AUTO", "minTemperature": 24.0, "maxTemperature": 24.0, "temperatureSettingPitchType": 1.0,
         "enableSettings": ["temperature": true, "humidity": false],
         "enableFanSpeed": ["AUTO": true, "LV1": true, "LV5": true], "defaultFanSpeed": ["AUTO": true]],
    ],
]

final class SignInTests: XCTestCase {
    func testPhoneUsesMobileNumberWithPlusCountryCode() {
        let f = SignInMethod.phone(countryCode: "91", number: "90000 00001").credentialField
        XCTAssertEqual(f.field, "mobileNumber")
        XCTAssertEqual(f.value, "+919000000001")
    }

    func testPhoneStripsRepeatedCountryCodeAndTrunkZero() {
        XCTAssertEqual(SignInMethod.phone(countryCode: "+91", number: "+91 90000 00001").credentialField.value, "+919000000001")
        XCTAssertEqual(SignInMethod.phone(countryCode: "91", number: "090000 00001").credentialField.value, "+919000000001")
    }

    func testEmailIsTrimmed() {
        let f = SignInMethod.email("  someone@example.com \n").credentialField
        XCTAssertEqual(f.field, "email")
        XCTAssertEqual(f.value, "someone@example.com")
    }
}

final class STOMPTests: XCTestCase {
    func testConnectedWithAndWithoutUser() {
        XCTAssertEqual(STOMP.parse("CONNECTED\nversion:1.2\nuser-name:x\n\n\0"), .connected(authenticated: true))
        XCTAssertEqual(STOMP.parse("CONNECTED\nversion:1.2\n\n\0"), .connected(authenticated: false))
    }

    func testMessageWithUnits() {
        let frame = "MESSAGE\ndestination:/notification/1/1\ncontent-type:application/json\n\n"
            + #"{"notificationType":"ON_CONNECT","data":[{"id":1,"name":"Living Room"}]}"# + "\0"
        guard case .units(let list) = STOMP.parse(frame) else { return XCTFail("expected units") }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(ACUnit(json: list[0])?.id, "1")
    }

    func testEmptyHomeIsAValidAnswer() {
        guard case .units(let list) = STOMP.parse("MESSAGE\nx:y\n\n{\"data\":[]}\0") else { return XCTFail("expected units") }
        XCTAssertTrue(list.isEmpty)
    }

    func testSubscribeTargetsFamilyTopic() {
        XCTAssertTrue(STOMP.connectAndSubscribe(token: "t", familyId: "42").contains("destination:/notification/42/42"))
    }
}

final class CapabilitiesTests: XCTestCase {
    func testParsesModesSwingsAndFans() throws {
        let caps = try XCTUnwrap(Capabilities(modelConfig: coolingOnlyModel))
        XCTAssertEqual(caps.modes, ["COOLING", "DRY", "FAN", "AUTO"])
        XCTAssertEqual(caps.swings, ["OFF", "VERTICAL"])
        XCTAssertEqual(caps.byMode["FAN"]?.fans, ["LV1", "LV2", "LV3", "LV4", "LV5"])
        XCTAssertEqual(caps.byMode["FAN"]?.defaultFan, "LV2")
        XCTAssertEqual(caps.byMode["COOLING"]?.temperatureStep, 0.5)
    }
}

final class CommandFittingTests: XCTestCase {
    var caps: Capabilities!
    var unit: ACUnit!

    override func setUp() {
        caps = Capabilities(modelConfig: coolingOnlyModel)
        unit = ACUnit(id: "7", name: "Living Room", power: "ON", mode: "COOLING", iduTemperature: 25,
                      fanSpeed: "LV2", fanSwing: "OFF", sysType: 1, capabilities: caps)
    }

    func fit(_ d: DesiredState) throws -> [String: Any] { try CommandFitting.body(for: d, unit: unit, capabilities: caps) }

    func testLegacyFanNamesMapToLevels() throws {
        XCTAssertEqual(try fit(DesiredState(fanSpeed: "LOW"))["fanSpeed"] as? String, "LV1")
        XCTAssertEqual(try fit(DesiredState(fanSpeed: "HIGH"))["fanSpeed"] as? String, "LV5")
    }

    func testFanNotAllowedInModeFallsBackToModeDefault() throws {
        XCTAssertEqual(try fit(DesiredState(mode: "DRY", fanSpeed: "LV4"))["fanSpeed"] as? String, "AUTO")
    }

    func testUnsupportedSwingIsFitted() throws {
        XCTAssertEqual(try fit(DesiredState(fanSwing: "BOTH"))["fanSwing"] as? String, "VERTICAL")
        XCTAssertEqual(try fit(DesiredState(fanSwing: "HORIZONTAL"))["fanSwing"] as? String, "OFF")
    }

    func testTemperatureSnapsToStepAndRange() throws {
        XCTAssertEqual(try fit(DesiredState(temperature: 23.3))["iduTemperature"] as? Double, 23.5)
        XCTAssertEqual(try fit(DesiredState(temperature: 40))["iduTemperature"] as? Double, 32)
        XCTAssertEqual(try fit(DesiredState(mode: "AUTO"))["iduTemperature"] as? Double, 24)
    }

    func testFanModeSendsNoTemperature() throws {
        XCTAssertNil(try fit(DesiredState(mode: "FAN"))["iduTemperature"])
    }

    func testSettingTemperatureTurnsUnitOn() throws {
        unit.power = "OFF"
        XCTAssertEqual(try fit(DesiredState(temperature: 24))["power"] as? String, "ON")
    }

    func testMissingModeIsRefused() {
        XCTAssertThrowsError(try fit(DesiredState(mode: "HEATING"))) { error in
            XCTAssertEqual(error as? AirCloudError, .unsupportedMode("HEATING"))
        }
    }

    func testResidentialUnitsGetHumidityField() throws {
        let body = try fit(DesiredState())
        XCTAssertEqual(body["humidity"] as? String, "0")
        XCTAssertEqual(body["relativeTemperature"] as? Double, 0)
    }
}
