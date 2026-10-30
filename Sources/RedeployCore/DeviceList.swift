import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public enum Transport: Sendable, Equatable {
        case wifi, usb, other(String)

        public init?(rawValue: String?) {
            switch rawValue {
            case nil: return nil
            case "localNetwork": self = .wifi
            case "wired": self = .usb
            case let raw?: self = .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .usb: "USB"
            case .other(let raw): raw
            }
        }
    }

    public let name: String
    public let model: String
    public let osVersion: String
    /// nil when the phone is paired but not reachable right now.
    public let transport: Transport?
}

/// The slice of `devicectl list devices --json-output` the app reads.
public struct DeviceList: Decodable, Sendable {
    struct Result: Decodable { let devices: [Device] }
    struct Device: Decodable {
        struct Hardware: Decodable { let udid: String?; let marketingName: String? }
        struct Properties: Decodable { let name: String?; let osVersionNumber: String? }
        struct Connection: Decodable { let transportType: String? }
        let hardwareProperties: Hardware
        let deviceProperties: Properties
        let connectionProperties: Connection
    }

    let result: Result

    public static func decode(_ json: Data) throws -> DeviceList {
        try JSONDecoder().decode(DeviceList.self, from: json)
    }

    public func find(udid: String) -> DeviceInfo? {
        guard let device = result.devices.first(where: { $0.hardwareProperties.udid == udid }) else { return nil }
        return DeviceInfo(
            name: device.deviceProperties.name ?? "",
            model: device.hardwareProperties.marketingName ?? "",
            osVersion: device.deviceProperties.osVersionNumber ?? "",
            transport: DeviceInfo.Transport(rawValue: device.connectionProperties.transportType)
        )
    }
}

/// The slice of `devicectl device info apps --json-output` the app reads.
public struct InstalledAppList: Decodable, Sendable {
    struct Result: Decodable { let apps: [App] }
    struct App: Decodable { let version: String? }

    let result: Result

    public static func decode(_ json: Data) throws -> InstalledAppList {
        try JSONDecoder().decode(InstalledAppList.self, from: json)
    }

    /// The first matching app's version, nil when it is not installed.
    public var version: String? {
        result.apps.first.map { $0.version ?? "?" }
    }
}
