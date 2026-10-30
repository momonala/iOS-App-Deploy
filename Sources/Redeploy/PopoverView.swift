import RedeployCore
import SwiftUI

private enum Metrics {
    static let width: CGFloat = 432
    static let outer: CGFloat = 8
    static let rowRadius: CGFloat = 6
    static let iconSize: CGFloat = 28
    static let iconRadius: CGFloat = 7
    static let columnGap: CGFloat = 12
    static let small: CGFloat = 11
    static let mono: CGFloat = 10.5
    static let nestIndent: CGFloat = 12
}

struct PopoverView: View {
    let model: AppModel
    @State private var expandedOverride: [String: Bool] = [:]
    @State private var hovered: String?
    @State private var phoneExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.configError {
                Text(error)
                    .font(.system(size: Metrics.small))
                    .foregroundStyle(.red)
                    .padding(.horizontal, Metrics.outer)
                    .padding(.bottom, 4)
            }
            SectionLabel("Phone")
            phoneRow
            Divider().padding(.horizontal, Metrics.outer).padding(.vertical, 4)
            SectionLabel("Apps")
            ForEach(model.apps) { app in
                appRow(app)
            }
            Divider().padding(.horizontal, Metrics.outer).padding(.vertical, 4)
            footer
        }
        .padding(Metrics.outer)
        .frame(width: Metrics.width)
        // MenuBarExtra keeps its window alive between openings, so onAppear does not fire on reopen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshForDisplay()
        }
    }

    private var header: some View {
        HStack {
            Text("iOS App Deploy").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Deploy All") { Task { await model.deployAll() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isChecking || model.isDeploying)
                .help("Redeploy every app now, regardless of time left")
            if model.isChecking {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            } else {
                Button { Task { await model.check() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Check now and redeploy anything close to expiring")
            }
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Button("Edit Config…") { model.openConfig() }
                Button("Open Logs Folder") { model.openLogsFolder() }
                Divider()
                Button("Quit iOS App Deploy") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var phoneRow: some View {
        PhoneRow(phone: model.phone, name: model.deviceName, udid: model.config?.device.udid ?? "", expanded: phoneExpanded)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .fill(Color.primary.opacity(phoneExpanded || hovered == "phone" ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? "phone" : (hovered == "phone" ? nil : hovered) }
            .onTapGesture { phoneExpanded.toggle() }
        if phoneExpanded {
            PhoneDetail(model: model)
                .task { await model.refreshPhoneDetails() }
        }
    }

    @ViewBuilder
    private func appRow(_ app: AppStatus) -> some View {
        let isFailed = if case .failed = app.phase { true } else { false }
        let expanded = expandedOverride[app.id] ?? isFailed
        AppRow(app: app, thresholdDays: model.thresholdDays, expanded: expanded)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .fill(Color.primary.opacity(expanded || hovered == app.id ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? app.id : (hovered == app.id ? nil : hovered) }
            .onTapGesture { expandedOverride[app.id] = !expanded }
            .contextMenu {
                Button("Open in Xcode") { model.openProject(app.id) }
                Button("Copy Bundle ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.config.bundleId, forType: .string)
                }
            }
        if expanded {
            AppDetail(app: app, model: model)
                .task(id: app.id) {
                    async let installed: Void = model.refreshOnPhone(app.id)
                    async let crashes: Void = model.refreshCrashes()
                    await model.refreshWiFiSync()
                    _ = await (installed, crashes)
                }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerStatus)
            Spacer()
            if let due = model.nextRedeployDue {
                TimelineView(.everyMinute) { context in
                    Text(due <= context.date ? "Redeploy due" : "Redeploys in \(Policy.remainingText(until: due, now: context.date))")
                }
                .help("At the first daily check once an app is down to \(model.thresholdDays ?? 0)d left")
            }
        }
        .font(.system(size: Metrics.small))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, Metrics.outer)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var footerStatus: String {
        if model.isDeploying { return "Deploying…" }
        if model.isChecking { return "Checking…" }
        guard let last = model.state.lastCheck else { return "Not updated yet" }
        let failed = model.failedCount
        return "Updated \(Format.relativeDateTime(last))" + (failed > 0 ? " · \(failed) failed" : "")
    }
}

private struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: Metrics.small, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.outer)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private struct PhoneRow: View {
    let phone: Phone
    let name: String
    let udid: String
    let expanded: Bool

    var body: some View {
        HStack(spacing: Metrics.columnGap) {
            Image(systemName: "iphone")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(phone.info?.name ?? name).fontWeight(.medium)
                Text(subtitle)
                    .font(.system(size: Metrics.small))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            status
            Chevron(expanded: expanded)
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .help(udid)
        .contextMenu {
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(udid, forType: .string)
            }
        }
    }

    private var subtitle: String {
        if case .unreachable = phone { return "Same Wi-Fi? Phone unlocked?" }
        guard let info = phone.info else { return udid }
        return "\(info.model) · iOS \(info.osVersion)"
    }

    @ViewBuilder
    private var status: some View {
        switch phone {
        case .checking:
            ProgressView().controlSize(.mini)
        case .connected(let info):
            StatusLabel(text: info.transport?.label ?? "", color: .green)
        case .unreachable:
            StatusLabel(text: "Not reachable", color: .red)
        }
    }
}

private struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.system(size: Metrics.small))
        .foregroundStyle(.secondary)
    }
}

private struct AppRow: View {
    let app: AppStatus
    let thresholdDays: Int?
    let expanded: Bool

    var body: some View {
        HStack(spacing: Metrics.columnGap) {
            AppIcon(image: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.config.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 6)
                    if let version = app.record?.version {
                        Text(version)
                            .font(.system(size: Metrics.small))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                subtitle
                if case .deploying(let step, let total, _, _) = app.phase {
                    ProgressView(value: Double(step), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Chevron(expanded: expanded)
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var subtitle: some View {
        Group {
            switch app.phase {
            case .deploying(let step, let total, let title, let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    let clock = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(2)
                        Text(step > 0 ? "Step \(step) of \(total) · \(clock)" : clock)
                    }
                }
                .foregroundStyle(.secondary)
            case .failed(_, let at):
                Text("Failed \(Format.relativeDateTime(at))").foregroundStyle(.red)
            case .waitingForPhone:
                Text("Waiting for phone").foregroundStyle(.secondary)
            case .idle:
                if let expiry = app.expiresAt {
                    TimelineView(.everyMinute) { context in
                        expiryLine(expiry, now: context.date)
                    }
                } else {
                    Text("Never deployed").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: Metrics.small))
        .monospacedDigit()
        .lineLimit(1)
    }

    private func expiryLine(_ expiry: Date, now: Date) -> some View {
        let color: Color = expiry <= now ? .red
            : thresholdDays.map { Policy.needsDeploy(expiresAt: expiry, now: now, thresholdDays: $0) } == true ? .orange
            : .secondary
        return HStack(spacing: 4) {
            Text(Format.dateTime(expiry))
            Text("·")
            Text(Policy.remainingText(until: expiry, now: now))
        }
        .foregroundStyle(color)
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.iconRadius, style: .continuous))
    }
}

private struct AppDetail: View {
    let app: AppStatus
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: Metrics.columnGap, verticalSpacing: 3) {
                if case .failed(let message, _) = app.phase {
                    DetailRow("Error") { Text(message).foregroundStyle(.red) }
                }
                DetailRow("Bundle ID") { MonoText(app.config.bundleId) }
                if let profile = app.profile {
                    DetailRow("Profile") { MonoText(profile.uuid) }
                    DetailRow("Signed", nested: true) { Text("\(Format.dateTime(profile.creationDate)) · team \(profile.teamID)") }
                }
                if let installed = model.installedProfiles {
                    DetailRow("On phone", nested: app.profile != nil) {
                        Text(phoneProfileText(installed.readAt))
                            .foregroundStyle(app.phoneProfile == nil ? Color.orange : .primary)
                    }
                    ForEach(app.extensionProfiles, id: \.bundleId) { profile in
                        DetailRow(extensionName(profile.bundleId), nested: true) {
                            Text("Expires \(Format.dateTime(profile.expirationDate))")
                        }
                    }
                }
                if let record = app.record {
                    DetailRow("Last deploy") {
                        Text("\(Format.dateTime(record.installedAt)) · \(Policy.durationText(seconds: record.durationSeconds))")
                    }
                    DetailRow("Source", nested: true) {
                        HStack(spacing: 0) {
                            MonoText(record.commit)
                            Text(" on \(record.branch), \(record.dirty ? "uncommitted changes" : "clean")")
                        }
                    }
                    if let subject = record.subject {
                        DetailRow("Commit", nested: true) { Text(subject).lineLimit(1).help(subject) }
                    }
                } else {
                    DetailRow("Last deploy") { Text("Not recorded yet").foregroundStyle(.secondary) }
                }
                DetailRow("Installed") { Text(installedText) }
                if let crashes = model.crashes {
                    DetailRow("Crashes") {
                        Text(crashText)
                            .foregroundStyle(crashedSinceDeploy ? Color.orange : .primary)
                    }
                    if !Calendar.current.isDateInToday(crashes.readAt) {
                        DetailRow("Read", nested: true) {
                            Text(Format.relativeDateTime(crashes.readAt)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    DetailRow("Crashes") { Text("Reading…").foregroundStyle(.secondary) }
                }
            }
            .font(.system(size: Metrics.small))
            .textSelection(.enabled)

            HStack(spacing: 8) {
                let isFailed = if case .failed = app.phase { true } else { false }
                Button(isFailed ? "Retry" : "Deploy Now") { Task { await model.deploy(app.id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isDeploying)
                Button("Open Log") { model.openLog(app.id) }
                    .disabled(app.lastLog == nil)
                Button("Xcode") { model.openProject(app.id) }
                    .help("Open in Xcode")
                if !app.crashes.isEmpty {
                    Button(model.pullingCrash == app.id ? "Pulling…" : "Open Latest Crash") {
                        Task { await model.openLatestCrash(app.id) }
                    }
                    .disabled(model.pullingCrash != nil)
                    .help(app.crashes[0].fileName)
                }
            }
            .controlSize(.small)
            if let error = model.crashCopyErrors[app.id] {
                Text(error)
                    .font(.system(size: Metrics.small))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var crashedSinceDeploy: Bool {
        guard let newest = app.crashes.first, let deployed = app.record?.installedAt else { return false }
        return newest.date > deployed
    }

    private var crashText: String {
        guard let newest = app.crashes.first else { return "None on phone" }
        let since = crashedSinceDeploy ? ", since deploy" : ""
        return "\(app.crashes.count) · newest \(Format.relativeDateTime(newest.date))\(since)"
    }

    private func phoneProfileText(_ readAt: Date) -> String {
        guard let phone = app.phoneProfile else { return "No profile for this app" }
        if let profile = app.profile, profile.uuid.caseInsensitiveCompare(phone.uuid) == .orderedSame {
            return "Same profile"
        }
        if let installed = app.record?.installedAt, readAt < installed {
            return "Not read since last deploy"
        }
        return "Different, expires \(Format.dateTime(phone.expirationDate))"
    }

    private func extensionName(_ bundleId: String) -> String {
        String(bundleId.dropFirst(app.config.bundleId.count + 1))
    }

    private var installedText: String {
        switch app.onPhone {
        case .unknown, .checking: "Checking…"
        case .installed(let version): version
        case .notInstalled: "Not installed"
        case .unavailable: "Phone not reachable"
        }
    }
}

private struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeOut(duration: 0.16), value: expanded)
    }
}

private struct PhoneDetail: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: Metrics.columnGap, verticalSpacing: 3) {
                if let phone = model.phoneDetails {
                    DetailRow("Model") { Text("\(phone.model) · \(phone.productType) · \(phone.hardwareModel)") }
                    if let bytes = phone.storageBytes {
                        DetailRow("Storage", nested: true) { Text(bytes.formatted(.byteCount(style: .decimal))) }
                    }
                    DetailRow("Serial", nested: true) { MonoText(phone.serial) }
                    DetailRow("UDID", nested: true) { MonoText(phone.udid) }
                    DetailRow("ECID", nested: true) { MonoText(phone.ecid) }
                    DetailRow("iOS") { Text("\(phone.osVersion) (\(phone.osBuild))") }
                    DetailRow("Developer", nested: true) {
                        Text("Mode \(phone.developerModeEnabled ? "on" : "off") · disk image \(phone.diskImageServicesAvailable ? "ready" : "unavailable")")
                            .foregroundStyle(phone.developerModeEnabled ? .primary : Color.red)
                    }
                } else {
                    DetailRow("Details") { Text("Reading…").foregroundStyle(.secondary) }
                }
                if let lock = model.lockState {
                    DetailRow("Lock") {
                        Text(lock.unlockedSinceBoot ? (lock.passcodeRequired ? "Locked" : "Unlocked") : "Not unlocked since boot")
                            .foregroundStyle(lock.unlockedSinceBoot ? .primary : Color.red)
                    }
                }
                if let phone = model.phoneDetails {
                    DetailRow("Connection") { Text(connectionText(phone)) }
                }
                batteryRows
            }
            .font(.system(size: Metrics.small))
            .monospacedDigit()
            .textSelection(.enabled)

            if let url = model.phoneDetails?.devicesURL {
                Button("Open in Xcode Devices") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Metrics.outer)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var batteryRows: some View {
        if let battery = model.battery {
            DetailRow("Battery") {
                Text(chargeText(battery))
            }
            DetailRow("Health", nested: true) {
                Text("\(battery.healthPercent)% · \(battery.cycleCount.formatted()) cycles")
                    .foregroundStyle(battery.healthPercent < 80 ? Color.orange : .primary)
            }
            DetailRow("Temperature", nested: true) {
                Text(battery.temperatureCelsius.formatted(.number.precision(.fractionLength(1))) + " °C")
            }
            DetailRow("Read", nested: true) {
                Text(Format.relativeDateTime(battery.readAt) + (model.wifiSyncProblem == nil ? "" : " · not visible now"))
                    .foregroundStyle(.secondary)
            }
        } else {
            DetailRow("Battery") { Text(model.wifiSyncProblem ?? "Reading…").foregroundStyle(.secondary) }
        }
    }

    private func chargeText(_ battery: BatterySnapshot) -> String {
        guard battery.isCharging || battery.chargerWatts != nil else { return "\(battery.chargePercent)%" }
        let charger = battery.chargerWatts.map { " (\($0) W)" } ?? ""
        return "\(battery.chargePercent)%, \(battery.isCharging ? "charging" : "plugged in")\(charger)"
    }

    private func connectionText(_ phone: PhoneDetails) -> String {
        var parts = [phone.transport?.label ?? "Not connected"]
        if let tunnel = phone.tunnelState { parts.append("tunnel \(tunnel)") }
        if phone.transport == nil, let seen = phone.lastConnection { parts.append("seen \(Format.relativeDateTime(seen))") }
        return parts.joined(separator: " · ")
    }
}

private struct DetailRow<Value: View>: View {
    let label: String
    let nested: Bool
    let value: Value

    init(_ label: String, nested: Bool = false, @ViewBuilder value: () -> Value) {
        self.label = label
        self.nested = nested
        self.value = value()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .padding(.leading, nested ? Metrics.nestIndent : 0)
                .gridColumnAlignment(.leading)
            value
        }
    }
}

private struct MonoText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: Metrics.mono, design: .monospaced))
    }
}
