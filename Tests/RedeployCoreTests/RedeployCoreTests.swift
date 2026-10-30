import Foundation
import Testing
@testable import RedeployCore

private let now = ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z")!
private let day: TimeInterval = 86400

@Test func profileIsCutOutOfTheSignedEnvelope() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Name</key><string>iOS Team Provisioning Profile: mnalavadi.Trace</string>
      <key>UUID</key><string>00000000-0000-4000-8000-000000000001</string>
      <key>TeamIdentifier</key><array><string>52K2BR328Z</string></array>
      <key>CreationDate</key><date>2026-10-28T08:55:25Z</date>
      <key>ExpirationDate</key><date>2026-11-04T08:55:25Z</date>
    </dict></plist>
    """
    let envelope = Data([0x30, 0x80, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0x00])

    let profile = try ProvisioningProfile(data: envelope)

    #expect(profile.uuid == "00000000-0000-4000-8000-000000000001")
    #expect(profile.teamID == "52K2BR328Z")
    #expect(profile.expirationDate == ISO8601DateFormatter().date(from: "2026-11-04T08:55:25Z"))
    #expect(throws: ProvisioningProfile.ParseError.noPlist) { try ProvisioningProfile(data: Data("junk".utf8)) }
}

@Test(arguments: [
    (5.0, false),
    (4.0, true),
    (1.0, true),
    (-1.0, true),
])
func deploysAtOrUnderTheThreshold(daysLeft: Double, expected: Bool) {
    #expect(Policy.needsDeploy(expiresAt: now + daysLeft * day, now: now, thresholdDays: 4) == expected)
}

@Test func deploysWhenNothingIsInstalled() {
    #expect(Policy.needsDeploy(expiresAt: nil, now: now, thresholdDays: 4))
}

@Test func automaticCheckRunsOncePerCalendarDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!

    #expect(Policy.automaticCheckDue(lastSuccess: nil, now: now, calendar: calendar))
    #expect(!Policy.automaticCheckDue(lastSuccess: now - 3600, now: now, calendar: calendar))
    #expect(Policy.automaticCheckDue(lastSuccess: now - day, now: now, calendar: calendar))
}

@Test func remainingAndDurationText() {
    #expect(Policy.remainingText(until: now + 4 * day + 23 * 3600 + 12 * 60 + 59, now: now) == "4d 23h 12m")
    #expect(Policy.remainingText(until: now - 1, now: now) == "Expired")
    #expect(Policy.durationText(seconds: 112) == "1m 52s")
    #expect(Policy.durationText(seconds: 48) == "48s")
}

@Test func scriptLines() {
    #expect(ScriptLine("[3/5] Building") == .step(index: 3, total: 5, title: "Building"))
    #expect(ScriptLine("error install failed after 3 attempts") == .error("install failed after 3 attempts"))
    #expect(ScriptLine("      ✓ built 7.0M") == .other)
}

@Test func findsThePinnedPhoneAndItsTransport() throws {
    let json = """
    {"result": {"devices": [
      {"hardwareProperties": {"udid": "SIM-1", "marketingName": "iPhone 16"},
       "deviceProperties": {"name": "Simulator"}, "connectionProperties": {}},
      {"hardwareProperties": {"udid": "00008110-0000000000000001", "marketingName": "iPhone 13"},
       "deviceProperties": {"name": "Momo", "osVersionNumber": "26.7.1"},
       "connectionProperties": {"transportType": "localNetwork", "pairingState": "paired"}}
    ]}}
    """
    let list = try DeviceList.decode(Data(json.utf8))

    let phone = try #require(list.find(udid: "00008110-0000000000000001"))
    #expect(phone == DeviceInfo(name: "Momo", model: "iPhone 13", osVersion: "26.7.1", transport: .wifi))
    #expect(list.find(udid: "SIM-1")?.transport == nil)
    #expect(list.find(udid: "missing") == nil)
}

@Test func batteryHealthIsFullChargeOverDesignCapacity() throws {
    let json = """
    {"CurrentCapacity": 97, "IsCharging": true, "ExternalConnected": true, "AdapterDetails": {"Watts": 15},
     "CycleCount": 1407, "DesignCapacity": 3208, "NominalChargeCapacity": 2464, "Temperature": 2459,
     "BatteryData": {"CycleCount": 1407}}
    """
    let battery = try BatterySnapshot.decode(Data(json.utf8), readAt: now)

    #expect(battery.healthPercent == 77)
    #expect(battery.cycleCount == 1407)
    #expect(battery.chargerWatts == 15)
    #expect(battery.temperatureCelsius == 24.59)
}

@Test func phoneDetailsAndLockState() throws {
    let details = """
    {"result": {
      "deviceProperties": {"osVersionNumber": "26.7.1", "osBuildUpdate": "23H30", "developerModeStatus": "enabled",
                           "ddiServicesAvailable": true, "screenViewingURL": "devices://device/open?id=6CD7"},
      "hardwareProperties": {"marketingName": "iPhone 13", "productType": "iPhone14,5", "hardwareModel": "D17AP",
                             "internalStorageCapacity": 128000000000, "serialNumber": "P39D", "udid": "0000", "ecid": 1821350474973214},
      "connectionProperties": {"transportType": "localNetwork", "tunnelState": "connected",
                               "lastConnectionDate": "2026-10-30T10:35:00.000Z"}
    }}
    """
    let phone = try PhoneDetails.decode(Data(details.utf8))
    #expect(phone.ecid == "1821350474973214")
    #expect(phone.transport == .wifi)
    #expect(phone.developerModeEnabled)
    #expect(phone.lastConnection == ISO8601DateFormatter().date(from: "2026-10-30T10:35:00Z"))

    let lock = try LockState.decode(Data(#"{"result": {"passcodeRequired": true, "unlockedSinceBoot": true}}"#.utf8))
    #expect(lock == LockState(passcodeRequired: true, unlockedSinceBoot: true))
}

@Test func crashListKeepsOnlyTheAppsOwnReportsNewestFirst() throws {
    let names = [
        "Trace-2026-10-29-180107.ips", "Trace.cpu_resource-2026-10-20-172552.ips", "Retired",
        "SiriSearchFeedback-2026-10-23-145937.ips", "Trace-2026-10-30-091122.ips",
        "TraceWidgetsExtension-2026-10-01-080000.ips",
    ]
    let json = #"{"result": {"files": ["# + names.map { #"{"name": "\#($0)"}"# }.joined(separator: ",") + "]}}"
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    let crashes = try CrashReport.decode(Data(json.utf8), processes: ["Trace", "TraceWidgetsExtension"], timeZone: berlin)

    #expect(crashes.map(\.fileName) == [
        "Trace-2026-10-30-091122.ips", "Trace-2026-10-29-180107.ips", "TraceWidgetsExtension-2026-10-01-080000.ips",
    ])
    #expect(crashes.first?.date == ISO8601DateFormatter().date(from: "2026-10-30T08:11:22Z"))
}

@Test func installedProfilesResolveToTheNewestPerBundleID() throws {
    func entry(_ bundleId: String, _ uuid: String, _ created: String, _ expires: String) -> String {
        """
        {"UUID": "\(uuid)", "CreationDate": "\(created)", "ExpirationDate": "\(expires)",
         "Entitlements": {"application-identifier": "52K2BR328Z.\(bundleId)"}, "DER-Encoded-Profile": {"$hex": "30"}}
        """
    }
    let json = "[" + [
        entry("mnalavadi.Trace", "old", "2026-10-28T08:55:25", "2026-11-04T08:55:25"),
        entry("mnalavadi.Trace", "new", "2026-10-30T10:10:57", "2026-11-06T10:10:57"),
        entry("mnalavadi.Trace.TraceWidgets", "widget", "2026-10-30T10:10:55", "2026-11-06T10:10:55"),
        entry("mnalavadi.Urban-Sports-Club", "usc", "2026-10-30T10:11:17", "2026-11-06T10:11:17"),
    ].joined(separator: ",") + "]"

    let profiles = try InstalledProfile.decode(Data(json.utf8))

    #expect(profiles.newest(for: "mnalavadi.Trace")?.uuid == "new")
    #expect(profiles.newest(for: "mnalavadi.Trace")?.expirationDate == ISO8601DateFormatter().date(from: "2026-11-06T10:10:57Z"))
    #expect(profiles.newestExtensions(of: "mnalavadi.Trace").map(\.uuid) == ["widget"])
}
