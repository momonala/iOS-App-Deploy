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
    (4.0 + 1 / 86400, false),
    (4.0, true),
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

@Test func phoneDetailsMapEcidTransportAndConnectionDate() throws {
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
    ].joined(separator: ",") + "]"

    let profiles = try InstalledProfile.decode(Data(json.utf8))

    #expect(profiles.newest(for: "mnalavadi.Trace")?.uuid == "new")
    #expect(profiles.newest(for: "mnalavadi.Trace")?.expirationDate == ISO8601DateFormatter().date(from: "2026-11-06T10:10:57Z"))
    #expect(profiles.newestExtensions(of: "mnalavadi.Trace").map(\.uuid) == ["widget"])
}

@Test(arguments: [
    (day - 1, true),
    (day, true),
    (day + 1, false),
])
func urgentWithinADayOfExpiry(secondsLeft: TimeInterval, expected: Bool) {
    #expect(Policy.isUrgent(expiresAt: now + secondsLeft, now: now) == expected)
}

@Test func stateSurvivesASaveAndLoadWithISO8601Dates() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(url: directory.appending(path: "state.json"))
    var state = PersistedState()
    state.lastSuccessfulCheck = now
    state.apps["mnalavadi.Trace"] = RunState(health: .urgent(notifiedExpiry: now + day, failure: .phoneUnreachable))

    try store.save(state)

    #expect(try String(contentsOf: store.url, encoding: .utf8).contains(#""lastSuccessfulCheck" : "2026-10-30T10:00:00Z""#))
    #expect(store.load() == state)
}

@Test func stateWrittenByTheFlagBasedBuildLoadsAndSavesUnchanged() throws {
    let legacy = """
    {
      "apps" : {
        "failed" : {
          "failureNotified" : true,
          "lastError" : "install failed after 3 attempts",
          "lastErrorAt" : "2026-10-30T09:00:00Z",
          "lastLog" : "/logs/failed.log",
          "urgentNotifiedExpiry" : "2026-10-31T08:00:00Z"
        },
        "trace" : {
          "failureNotified" : false,
          "lastLog" : "/logs/trace.log"
        },
        "unreachable" : {
          "failureNotified" : true
        },
        "urgentOnly" : {
          "failureNotified" : false,
          "urgentNotifiedExpiry" : "2026-10-31T08:00:00Z"
        }
      },
      "battery" : {
        "chargePercent" : 100,
        "chargerWatts" : 15,
        "cycleCount" : 1411,
        "designCapacity" : 3208,
        "fullChargeCapacity" : 2478,
        "isCharging" : false,
        "readAt" : "2026-11-04T12:04:49Z",
        "temperatureCelsius" : 21.59
      },
      "lastCheck" : "2026-11-10T23:31:32Z",
      "lastSuccessfulCheck" : "2026-11-10T23:31:32Z"
    }
    """
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(url: directory.appending(path: "state.json"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(legacy.utf8).write(to: store.url)
    let date = { ISO8601DateFormatter().date(from: $0)! }

    let state = store.load()

    #expect(state.lastCheck == date("2026-11-10T23:31:32Z"))
    #expect(state.battery?.cycleCount == 1411)
    #expect(state.apps == [
        "trace": RunState(lastLog: "/logs/trace.log", health: .healthy),
        "unreachable": RunState(health: .failing(.phoneUnreachable)),
        "urgentOnly": RunState(health: .urgent(notifiedExpiry: date("2026-10-31T08:00:00Z"), failure: nil)),
        "failed": RunState(lastLog: "/logs/failed.log", health: .urgent(
            notifiedExpiry: date("2026-10-31T08:00:00Z"),
            failure: .deployFailed(message: "install failed after 3 attempts", at: date("2026-10-30T09:00:00Z"))
        )),
    ])

    try store.save(state)

    func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
    #expect(try json(Data(contentsOf: store.url)) == json(Data(legacy.utf8)))
}

private let expiry = now + day / 2
private let deployError = Failure.deployFailed(message: "install failed", at: now)

@Test(arguments: [
    AppHealth.healthy,
    .failing(.phoneUnreachable),
    .urgent(notifiedExpiry: expiry, failure: deployError),
])
func successStartsOverWithoutNotifying(from health: AppHealth) {
    #expect(health.applying(.deploySucceeded) == (.healthy, false))
}

@Test func firstFailureNotifiesAndLaterFailuresOnlyUpdateTheError() {
    let failed = AppHealth.healthy.applying(.deployFailed(message: "install failed", at: now))
    #expect(failed == (.failing(deployError), true))

    let again = AppHealth.failing(.phoneUnreachable).applying(.deployFailed(message: "install failed", at: now))
    #expect(again == (.failing(deployError), false))
}

@Test func unreachablePhoneNotifiesOnceAndKeepsAnEarlierDeployError() {
    #expect(AppHealth.healthy.applying(.phoneUnreachable) == (.failing(.phoneUnreachable), true))
    #expect(AppHealth.failing(.phoneUnreachable).applying(.phoneUnreachable) == (.failing(.phoneUnreachable), false))
    #expect(AppHealth.failing(deployError).applying(.phoneUnreachable) == (.failing(deployError), false))
}

@Test func failuresKeepTheUrgentNotice() {
    let urgent = AppHealth.urgent(notifiedExpiry: expiry, failure: nil)
    #expect(urgent.applying(.phoneUnreachable) == (.urgent(notifiedExpiry: expiry, failure: .phoneUnreachable), true))
    #expect(urgent.applying(.deployFailed(message: "install failed", at: now))
        == (.urgent(notifiedExpiry: expiry, failure: deployError), true))
}

@Test(arguments: [
    (day - 1, true),
    (day, true),
    (day + 1, false),
])
func urgentNoticeAtOrUnderADayLeft(secondsLeft: TimeInterval, notifies: Bool) {
    let expiresAt = now + secondsLeft
    let result = AppHealth.failing(deployError).applying(.expiryChecked(expiresAt: expiresAt, now: now))
    let expected: AppHealth = notifies ? .urgent(notifiedExpiry: expiresAt, failure: deployError) : .failing(deployError)
    #expect(result == (expected, notifies))
}

@Test func urgentNoticeIsSentOncePerExpiry() {
    let urgent = AppHealth.urgent(notifiedExpiry: expiry, failure: nil)
    #expect(urgent.applying(.expiryChecked(expiresAt: expiry, now: now)) == (urgent, false))

    let newExpiry = expiry + 3600
    #expect(urgent.applying(.expiryChecked(expiresAt: newExpiry, now: now))
        == (.urgent(notifiedExpiry: newExpiry, failure: nil), true))
}

@Test(arguments: [
    (Run.idle, Run.checking(deploying: nil)),
    (.deploying(appID: "trace"), .checking(deploying: "trace")),
])
func checkStartsWhenNoBatchIsRunning(from run: Run, to expected: Run) {
    #expect(run.applying(.check) == expected)
}

@Test(arguments: [Run.checking(deploying: nil), .checking(deploying: "trace"), .deployingAll(deploying: nil)])
func checkIsRefusedDuringABatch(_ run: Run) {
    #expect(run.applying(.check) == nil)
}

@Test func deployAllStartsOnlyWhenIdle() {
    #expect(Run.idle.applying(.deployAll) == .deployingAll(deploying: nil))
    for busy in [Run.deploying(appID: "trace"), .checking(deploying: nil), .deployingAll(deploying: nil)] {
        #expect(busy.applying(.deployAll) == nil)
    }
}

@Test(arguments: [
    (Run.idle, Run.deploying(appID: "usc")),
    (.checking(deploying: nil), .checking(deploying: "usc")),
    (.deployingAll(deploying: nil), .deployingAll(deploying: "usc")),
])
func deployStartsWhenNothingElseIsDeploying(from run: Run, to expected: Run) {
    #expect(run.applying(.deploy(appID: "usc")) == expected)
}

@Test(arguments: [Run.deploying(appID: "trace"), .checking(deploying: "trace"), .deployingAll(deploying: "trace")])
func deployIsRefusedWhileAnotherDeploys(_ run: Run) {
    #expect(run.applying(.deploy(appID: "usc")) == nil)
}

@Test(arguments: [
    (Run.deploying(appID: "trace"), Run.idle),
    (.checking(deploying: "trace"), .checking(deploying: nil)),
    (.deployingAll(deploying: "trace"), .deployingAll(deploying: nil)),
])
func finishedDeployLeavesTheBatchRunning(from run: Run, to expected: Run) {
    #expect(run.applying(.deployFinished) == expected)
}

@Test(arguments: [
    (Run.checking(deploying: nil), Run.idle),
    (.deployingAll(deploying: nil), .idle),
    (.checking(deploying: "trace"), .deploying(appID: "trace")),
    (.deployingAll(deploying: "trace"), .deploying(appID: "trace")),
])
func finishedBatchLeavesALoneDeployRunning(from run: Run, to expected: Run) {
    #expect(run.applying(.batchFinished) == expected)
}

@Test func busyFlagsFollowTheRun() {
    #expect(!Run.idle.isChecking && !Run.idle.isDeploying)
    #expect(!Run.deploying(appID: "trace").isChecking && Run.deploying(appID: "trace").isDeploying)
    #expect(Run.checking(deploying: nil).isChecking && !Run.checking(deploying: nil).isDeploying)
    #expect(Run.deployingAll(deploying: "trace").isChecking && Run.deployingAll(deploying: "trace").isDeploying)
}

@Test(arguments: [
    Phase.waitingForPhone,
    .deploying(step: 2, total: 5, title: "Building", startedAt: now),
])
func reloadKeepsLivePhases(_ phase: Phase) {
    #expect(phase.merging(persisted: deployError) == phase)
}

@Test(arguments: [Phase.idle, .failed(message: "older", at: now - day)])
func reloadRedrawsSettledPhasesFromTheSavedFailure(_ phase: Phase) {
    #expect(phase.merging(persisted: deployError) == .failed(message: "install failed", at: now))
    #expect(phase.merging(persisted: .phoneUnreachable) == .idle)
    #expect(phase.merging(persisted: nil) == .idle)
}

@Test func aSourceStartsOneReadAtATimeAndKeepsItsLastOutcome() throws {
    let settled = SourceState.idle(WiFiSync.notVisible)
    let reading = try #require(settled.beginning())

    #expect(reading == .reading(.notVisible))
    #expect(reading.isReading && reading.last == .notVisible)
    #expect(reading.beginning() == nil)
}

@Test(arguments: [
    (true, true, WiFiSync.visible),
    (true, false, .notVisible),
    (false, true, .notVisible),
    (false, false, .notVisible),
])
func wiFiSyncIsVisibleOnlyWhenBothReadsSucceed(battery: Bool, profiles: Bool, expected: WiFiSync) {
    #expect(WiFiSync(batteryRead: battery, profilesRead: profiles) == expected)
}

@Test func wiFiSyncProblems() {
    #expect(WiFiSync.unknown.problem == nil)
    #expect(WiFiSync.visible.problem == nil)
    #expect(WiFiSync.notVisible.problem == "Not visible to Wi-Fi sync right now")
    #expect(WiFiSync.missingTool.problem == "Needs pymobiledevice3: uv tool install pymobiledevice3")
}
