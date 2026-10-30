import Foundation

/// From `devicectl device info details --json-output`.
public struct PhoneDetails: Sendable, Equatable {
    public let model: String
    public let productType: String
    public let hardwareModel: String
    public let osVersion: String
    public let osBuild: String
    public let storageBytes: Int64?
    public let serial: String
    public let udid: String
    public let ecid: String
    public let developerModeEnabled: Bool
    public let diskImageServicesAvailable: Bool
    public let transport: DeviceInfo.Transport?
    public let tunnelState: String?
    public let lastConnection: Date?
    /// Opens the phone in Xcode's Devices window.
    public let devicesURL: URL?

    private struct Envelope: Decodable {
        struct Result: Decodable {
            struct Device: Decodable {
                let name: String?
                let osVersionNumber: String?
                let osBuildUpdate: String?
                let developerModeStatus: String?
                let ddiServicesAvailable: Bool?
                let screenViewingURL: String?
            }
            struct Hardware: Decodable {
                let marketingName: String?
                let productType: String?
                let hardwareModel: String?
                let internalStorageCapacity: Int64?
                let serialNumber: String?
                let udid: String?
                let ecid: Int64?
            }
            struct Connection: Decodable {
                let transportType: String?
                let tunnelState: String?
                let lastConnectionDate: String?
            }
            let deviceProperties: Device
            let hardwareProperties: Hardware
            let connectionProperties: Connection
        }
        let result: Result
    }

    public static func decode(_ json: Data) throws -> PhoneDetails {
        let result = try JSONDecoder().decode(Envelope.self, from: json).result
        let device = result.deviceProperties
        let hardware = result.hardwareProperties
        let connection = result.connectionProperties
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PhoneDetails(
            model: hardware.marketingName ?? "",
            productType: hardware.productType ?? "",
            hardwareModel: hardware.hardwareModel ?? "",
            osVersion: device.osVersionNumber ?? "",
            osBuild: device.osBuildUpdate ?? "",
            storageBytes: hardware.internalStorageCapacity,
            serial: hardware.serialNumber ?? "",
            udid: hardware.udid ?? "",
            ecid: hardware.ecid.map(String.init) ?? "",
            developerModeEnabled: device.developerModeStatus == "enabled",
            diskImageServicesAvailable: device.ddiServicesAvailable ?? false,
            transport: DeviceInfo.Transport(rawValue: connection.transportType),
            tunnelState: connection.tunnelState,
            lastConnection: connection.lastConnectionDate.flatMap(dateFormatter.date(from:)),
            devicesURL: device.screenViewingURL.flatMap(URL.init(string:))
        )
    }
}

/// From `devicectl device info lockState --json-output`.
public struct LockState: Decodable, Sendable, Equatable {
    public let passcodeRequired: Bool
    public let unlockedSinceBoot: Bool

    private struct Envelope: Decodable { let result: LockState }

    public static func decode(_ json: Data) throws -> LockState {
        try JSONDecoder().decode(Envelope.self, from: json).result
    }
}

/// The useful slice of `pymobiledevice3 diagnostics battery single`, which reads the phone's
/// AppleSmartBattery registry entry. Stored with the time it was read, because the phone is only
/// reachable this way while Wi-Fi sync can see it.
public struct BatterySnapshot: Codable, Sendable, Equatable {
    public let readAt: Date
    public let chargePercent: Int
    public let isCharging: Bool
    public let chargerWatts: Int?
    public let cycleCount: Int
    public let designCapacity: Int
    public let fullChargeCapacity: Int
    public let temperatureCelsius: Double

    public var healthPercent: Int {
        guard designCapacity > 0 else { return 0 }
        return Int((Double(fullChargeCapacity) / Double(designCapacity) * 100).rounded())
    }

    private struct Registry: Decodable {
        struct Adapter: Decodable { let Watts: Int? }
        let CurrentCapacity: Int
        let IsCharging: Bool
        let ExternalConnected: Bool?
        let AdapterDetails: Adapter?
        let CycleCount: Int
        let DesignCapacity: Int
        let NominalChargeCapacity: Int
        let Temperature: Int
    }

    public static func decode(_ json: Data, readAt: Date) throws -> BatterySnapshot {
        let registry = try JSONDecoder().decode(Registry.self, from: json)
        return BatterySnapshot(
            readAt: readAt,
            chargePercent: registry.CurrentCapacity,
            isCharging: registry.IsCharging,
            chargerWatts: registry.ExternalConnected == true ? registry.AdapterDetails?.Watts : nil,
            cycleCount: registry.CycleCount,
            designCapacity: registry.DesignCapacity,
            fullChargeCapacity: registry.NominalChargeCapacity,
            temperatureCelsius: Double(registry.Temperature) / 100
        )
    }
}
