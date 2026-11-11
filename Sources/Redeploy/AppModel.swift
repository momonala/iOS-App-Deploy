import AppKit
import Observation
import os
import RedeployCore
import ServiceManagement

enum Phone: Equatable {
    case checking(lastKnown: DeviceInfo?)
    case connected(DeviceInfo)
    case unreachable(lastKnown: DeviceInfo?)

    var info: DeviceInfo? {
        switch self {
        case .checking(let known), .unreachable(let known): known
        case .connected(let info): info
        }
    }

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}

enum OnPhone: Equatable {
    case unknown, installed(String), notInstalled, unavailable

    var isInstalled: Bool {
        if case .installed = self { true } else { false }
    }
}

struct AppStatus: Identifiable {
    var config: Config.App
    var profile: ProvisioningProfile?
    var record: InstallRecord?
    var phoneProfile: InstalledProfile?
    var extensionProfiles: [InstalledProfile] = []
    var crashes: [CrashReport] = []
    var phase: Phase = .idle
    var onPhone: SourceState<OnPhone> = .idle(.unknown)
    var lastLog: URL?
    var iconURL: URL?
    var icon: NSImage?

    var id: String { config.id }

    /// The phone's own profile wins when it is newer, as after a deploy straight from Xcode.
    var expiresAt: Date? {
        [profile?.expirationDate, phoneProfile?.expirationDate].compactMap { $0 }.max()
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var config: Config?
    private(set) var configError: String?
    private(set) var phone: Phone = .checking(lastKnown: nil)
    private(set) var apps: [AppStatus] = []
    private(set) var run: Run = .idle
    private(set) var state: PersistedState
    private(set) var launchAtLogin = false
    private(set) var phoneDetails: PhoneDetails?
    private(set) var lockState: LockState?
    private(set) var wifiSync: SourceState<WiFiSync> = .idle(.unknown)
    private(set) var pullingCrash: String?
    private(set) var crashCopyErrors: [String: String] = [:]

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    @ObservationIgnored private var crashList: SourceState<Void> = .idle(())
    @ObservationIgnored private let logger = Logger(subsystem: "mnalavadi.Redeploy", category: "model")

    init(store: StateStore = StateStore(), notifier: Notifier) {
        self.store = store
        self.notifier = notifier
        state = store.load()
    }

    var thresholdDays: Int? { config?.thresholdDays }
    var deviceName: String { config?.device.name ?? "Phone" }
    var battery: BatterySnapshot? { state.battery }
    var installedProfiles: Reading<[InstalledProfile]>? { state.installedProfiles }
    var crashes: Reading<[CrashReport]>? { state.crashes }
    var nextRedeployDue: Date? {
        guard let days = thresholdDays, !apps.isEmpty else { return nil }
        return apps.map { Policy.deployDueAt(expiresAt: $0.expiresAt, thresholdDays: days) ?? .distantPast }.min()
    }
    var failedCount: Int { apps.filter { if case .failed = $0.phase { true } else { false } }.count }

    var menuBarSymbol: String {
        if run.isDeploying { return "iphone.and.arrow.forward" }
        let attention = configError != nil || apps.contains { app in
            switch app.phase {
            case .failed, .waitingForPhone: true
            default: Policy.isUrgent(expiresAt: app.expiresAt, now: .now)
            }
        }
        return attention ? "iphone.badge.exclamationmark" : "iphone"
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onRetry = { [weak self] id in Task { await self?.deploy(id) } }
        notifier.onOpenLog = { NSWorkspace.shared.open($0) }
        notifier.setUp()
        registerLoginItemOnFirstRun()
        reload()

        // Wi-Fi is often still reconnecting right after wake or unlock, so give it a moment.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, delay: .seconds(30))
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked"), delay: .seconds(15))
        // A Mac that stays unlocked across midnight never fires either event.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAutomaticCheck(after: .zero) }
        }
        scheduleAutomaticCheck(after: .seconds(5))
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        pendingCheck?.cancel()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, delay: Duration) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAutomaticCheck(after: delay) }
        }
        observers.append((center, token))
    }

    /// Never cancels a check that is already running: cancelling its task would end the output
    /// stream, and that terminates the deploy script mid-install.
    private func scheduleAutomaticCheck(after delay: Duration) {
        guard run.applying(.check) != nil else { return }
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  Policy.automaticCheckDue(lastSuccess: state.lastSuccessfulCheck, now: .now)
            else { return }
            await check()
        }
    }

    // MARK: - Reading state

    func reload() {
        do {
            config = try Config.load(from: Paths.config)
            configError = nil
        } catch {
            configError = "Can't read \(Paths.config.path): \(error.localizedDescription)"
            return
        }
        let previous = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        apps = (config?.apps ?? []).map { app in
            var status = previous[app.id] ?? AppStatus(config: app)
            status.config = app
            status.record = try? InstallRecord.load(from: InstalledFiles.recordURL(bundleId: app.bundleId))
            status.profile = (try? ProvisioningProfile(contentsOf: InstalledFiles.profileURL(bundleId: app.bundleId)))
                ?? (try? ProvisioningProfile(contentsOf: app.builtAppURL.appending(path: "embedded.mobileprovision")))
            let executables = Set(Paths.executables(for: app))
            status.phoneProfile = state.installedProfiles?.value.newest(for: app.bundleId)
            status.extensionProfiles = state.installedProfiles?.value.newestExtensions(of: app.bundleId) ?? []
            status.crashes = state.crashes?.value.filter { executables.contains($0.process) } ?? []
            status.iconURL = Paths.icon(for: app)
            if status.icon == nil { status.icon = status.iconURL.flatMap(NSImage.init(contentsOf:)) }

            let saved = state.apps[app.id] ?? RunState()
            status.lastLog = saved.lastLog.map { URL(fileURLWithPath: $0) }
            status.phase = status.phase.merging(persisted: saved.health.failure)
            return status
        }
    }

    func refreshForDisplay() {
        reload()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard !run.isChecking else { return }
        Task { await refreshPhone() }
    }

    func refreshPhone() async {
        guard let config else { return }
        phone = .checking(lastKnown: phone.info)
        let json = Self.temporaryJSON()
        defer { try? FileManager.default.removeItem(at: json) }
        let status = await ProcessRunner.status(Paths.xcrun, ["devicectl", "list", "devices", "--json-output", json.path])
        let info = status == 0 ? (try? DeviceList.decode(Data(contentsOf: json)))?.find(udid: config.device.udid) : nil
        if let info, info.transport != nil {
            phone = .connected(info)
        } else {
            phone = .unreachable(lastKnown: info ?? phone.info)
        }
    }

    func refreshOnPhone(_ id: String) async {
        guard let config, let index = index(of: id), let reading = apps[index].onPhone.beginning() else { return }
        apps[index].onPhone = reading
        let json = Self.temporaryJSON()
        defer { try? FileManager.default.removeItem(at: json) }
        let status = await ProcessRunner.status(Paths.xcrun, [
            "devicectl", "device", "info", "apps", "--device", config.device.udid,
            "--bundle-id", apps[index].config.bundleId, "--json-output", json.path,
        ])
        guard let index = self.index(of: id) else { return }
        if status == 0, let list = try? InstalledAppList.decode(Data(contentsOf: json)) {
            apps[index].onPhone = .idle(list.version.map(OnPhone.installed) ?? .notInstalled)
        } else {
            apps[index].onPhone = .idle(.unavailable)
        }
    }

    func refreshPhoneDetails() async {
        guard let config else { return }
        let udid = config.device.udid
        async let details = Self.devicectlJSON(["device", "info", "details", "--device", udid])
        async let lock = Self.devicectlJSON(["device", "info", "lockState", "--device", udid])
        async let wifiSync: Void = refreshWiFiSync()
        phoneDetails = try? (await details).map(PhoneDetails.decode)
        lockState = try? (await lock).map(LockState.decode)
        await wifiSync
    }

    /// Battery and installed profiles. Reachable only while macOS's Wi-Fi sync (usbmux) can see the
    /// phone, which comes and goes, so the last good readings are kept and shown with their time.
    func refreshWiFiSync() async {
        guard let config, let reading = wifiSync.beginning() else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.pymobiledevice3.path) else {
            wifiSync = .idle(.missingTool)
            return
        }
        wifiSync = reading

        let udid = ["--udid", config.device.udid]
        async let battery = ProcessRunner.output(Paths.pymobiledevice3, ["diagnostics", "battery", "single"] + udid)
        async let profiles = ProcessRunner.output(Paths.pymobiledevice3, ["provision", "list"] + udid)
        let readAt = Date.now
        let (batteryStatus, batteryJSON) = await battery
        let (profilesStatus, profilesJSON) = await profiles

        let snapshot = batteryStatus == 0 ? try? BatterySnapshot.decode(Data(batteryJSON.utf8), readAt: readAt) : nil
        let installed = profilesStatus == 0 ? try? InstalledProfile.decode(Data(profilesJSON.utf8)) : nil
        if let snapshot { state.battery = snapshot }
        if let installed { state.installedProfiles = Reading(readAt: readAt, value: installed) }
        wifiSync = .idle(WiFiSync(batteryRead: snapshot != nil, profilesRead: installed != nil))
        save()
        reload()
    }

    func refreshCrashes() async {
        guard let config, let reading = crashList.beginning() else { return }
        crashList = reading
        defer { crashList = .idle(()) }
        let readAt = Date.now
        let json = await Self.devicectlJSON([
            "device", "info", "files", "--device", config.device.udid, "--domain-type", "systemCrashLogs",
        ])
        let executables = Set(config.apps.flatMap(Paths.executables))
        guard let json, let crashes = try? CrashReport.decode(json, processes: executables) else { return }
        state.crashes = Reading(readAt: readAt, value: crashes)
        save()
        reload()
    }

    private static func devicectlJSON(_ arguments: [String]) async -> Data? {
        let json = temporaryJSON()
        defer { try? FileManager.default.removeItem(at: json) }
        let status = await ProcessRunner.status(Paths.xcrun, ["devicectl"] + arguments + ["--json-output", json.path])
        return status == 0 ? try? Data(contentsOf: json) : nil
    }

    // MARK: - Checking and deploying

    func check() async {
        guard transition(.check) else { return }
        defer { transition(.batchFinished) }

        reload()
        guard let config else { return }
        for index in apps.indices where apps[index].phase == .waitingForPhone { apps[index].phase = .idle }
        await refreshPhone()
        await refreshWiFiSync()
        await refreshCrashes()

        var allSucceeded = true
        let due = apps.filter {
            Policy.needsDeploy(expiresAt: $0.expiresAt, now: .now, thresholdDays: config.thresholdDays)
        }
        for app in due {
            guard phone.isConnected else {
                setPhase(app.id, .waitingForPhone)
                if record(.phoneUnreachable, for: app.id) {
                    postFailure(
                        app.id,
                        title: "\(app.config.name) needs a redeploy",
                        body: "\(config.device.name) is not reachable. Retrying at next unlock.",
                        log: nil
                    )
                }
                allSucceeded = false
                continue
            }
            allSucceeded = await deploy(app.id) && allSucceeded
        }

        notifyUrgent()
        state.lastCheck = .now
        if allSucceeded { state.lastSuccessfulCheck = .now }
        save()
    }

    func deployAll() async {
        guard transition(.deployAll) else { return }
        defer { transition(.batchFinished) }

        reload()
        var allSucceeded = true
        for app in apps {
            allSucceeded = await deploy(app.id) && allSucceeded
        }
        state.lastCheck = .now
        if allSucceeded { state.lastSuccessfulCheck = .now }
        save()
    }

    @discardableResult
    func deploy(_ id: String) async -> Bool {
        guard let index = index(of: id), transition(.deploy(appID: id)) else { return false }
        let app = apps[index].config
        let log = Paths.newLog(for: id)
        let startedAt = Date.now
        apps[index].lastLog = log
        state.apps[id, default: RunState()].lastLog = log.path
        setPhase(id, .deploying(step: 0, total: 1, title: "Starting", startedAt: startedAt))

        var exitStatus: Int32 = -1
        var lastError: String?
        let events = ProcessRunner.run(
            Paths.deployScript, [id, "--no-launch"],
            extraEnvironment: ["REDEPLOY_LOG_FILE": log.path],
            log: log,
            timeout: .seconds(20 * 60)
        )
        for await event in events {
            switch event {
            case .line(let line):
                switch ScriptLine(line) {
                case .step(let step, let total, let title):
                    setPhase(id, .deploying(step: step, total: total, title: title, startedAt: startedAt))
                case .error(let message):
                    lastError = message
                case .other:
                    break
                }
            case .exit(let code):
                exitStatus = code
            }
        }
        Paths.pruneLogs(for: id)

        let succeeded = exitStatus == 0
        let failureMessage = lastError ?? "deploy-ios.sh exited with status \(exitStatus)"
        let notifyFailure = record(
            succeeded ? .deploySucceeded : .deployFailed(message: failureMessage, at: .now),
            for: id
        )
        setPhase(id, .idle)
        transition(.deployFinished)
        reload()
        save()

        let took = Policy.durationText(seconds: Int(Date.now.timeIntervalSince(startedAt)))
        let icon = self.index(of: id).flatMap { apps[$0].iconURL }
        if succeeded {
            let expiry = self.index(of: id).flatMap { apps[$0].expiresAt }
            notifier.post(
                title: "\(app.name) redeployed",
                body: "Good until \(expiry.map(Format.dateTime) ?? "unknown"). Took \(took).",
                appID: id, log: log, icon: icon, isFailure: false
            )
        } else if notifyFailure {
            postFailure(
                id,
                title: "\(app.name) deploy failed",
                body: "\(Format.sentence(failureMessage)). Retrying at next unlock.",
                log: log
            )
        }
        return succeeded
    }

    // MARK: - Notifications

    private func record(_ event: AppHealth.Event, for id: String) -> Bool {
        let current = state.apps[id]?.health ?? .healthy
        let (health, notify) = current.applying(event)
        if health != current { state.apps[id, default: RunState()].health = health }
        return notify
    }

    private func postFailure(_ id: String, title: String, body: String, log: URL?) {
        let icon = index(of: id).flatMap { apps[$0].iconURL }
        notifier.post(title: title, body: body, appID: id, log: log, icon: icon, isFailure: true)
    }

    private func notifyUrgent() {
        for app in apps {
            guard let expiry = app.expiresAt, record(.expiryChecked(expiresAt: expiry, now: .now), for: app.id)
            else { continue }
            let remaining = Policy.remainingText(until: expiry, now: .now)
            notifier.post(
                title: expiry <= .now ? "\(app.config.name) has expired" : "\(app.config.name) expires in \(remaining)",
                body: "Profile ends \(Format.dateTime(expiry)) and no redeploy has succeeded yet.",
                appID: app.id, log: app.lastLog, icon: app.iconURL, isFailure: true
            )
        }
    }

    // MARK: - Actions

    func openLog(_ id: String) {
        guard let log = index(of: id).flatMap({ apps[$0].lastLog }) else { return }
        NSWorkspace.shared.open(log)
    }

    func openProject(_ id: String) {
        guard let index = index(of: id) else { return }
        NSWorkspace.shared.open(apps[index].config.projectURL)
    }

    /// Copies the newest crash report off the phone once, then opens the local copy in Console.
    func openLatestCrash(_ id: String) async {
        guard let config, pullingCrash == nil,
              let crash = index(of: id).flatMap({ apps[$0].crashes.first })
        else { return }
        crashCopyErrors[id] = nil
        let local = Paths.crashes.appending(path: crash.fileName)
        if !FileManager.default.fileExists(atPath: local.path) {
            pullingCrash = id
            defer { pullingCrash = nil }
            try? FileManager.default.createDirectory(at: Paths.crashes, withIntermediateDirectories: true)
            let status = await ProcessRunner.status(Paths.xcrun, [
                "devicectl", "device", "copy", "from", "--device", config.device.udid,
                "--domain-type", "systemCrashLogs", "--source", crash.fileName, "--destination", local.path,
            ], timeout: .seconds(90))
            guard status == 0, FileManager.default.fileExists(atPath: local.path) else {
                crashCopyErrors[id] = "Couldn't copy the crash report. Is \(config.device.name) reachable?"
                return
            }
        }
        NSWorkspace.shared.open(local)
    }

    func openConfig() { NSWorkspace.shared.open(Paths.config) }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.logs)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            logger.error("launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func registerLoginItemOnFirstRun() {
        let key = "registeredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    // MARK: - Helpers

    private func index(of id: String) -> Int? { apps.firstIndex { $0.id == id } }

    @discardableResult
    private func transition(_ event: Run.Event) -> Bool {
        guard let next = run.applying(event) else { return false }
        run = next
        return true
    }

    private func setPhase(_ id: String, _ phase: Phase) {
        guard let index = index(of: id) else { return }
        apps[index].phase = phase
    }

    private func save() {
        do { try store.save(state) } catch { logger.error("saving state: \(error.localizedDescription)") }
    }

    private static func temporaryJSON() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "redeploy-\(UUID().uuidString).json")
    }
}

enum Format {
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "Wed 4 Nov, 09:55"
    static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    /// "today 07:41", or the full date for any other day.
    static func relativeDateTime(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? "today \(timeFormatter.string(from: date))" : dateTime(date)
    }

    static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
