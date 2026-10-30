import Foundation

public struct ProvisioningProfile: Sendable, Equatable {
    public let name: String
    public let uuid: String
    public let teamID: String
    public let creationDate: Date
    public let expirationDate: Date

    public enum ParseError: Error, Equatable {
        case noPlist
        case missingField(String)
    }

    /// A .mobileprovision is a CMS envelope around an XML plist, so the plist can be cut straight out
    /// of the bytes without going through the Security framework.
    public init(data: Data) throws {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { throw ParseError.noPlist }

        let plist = try PropertyListSerialization.propertyList(
            from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
        ) as? [String: Any] ?? [:]

        func field<T>(_ key: String) throws -> T {
            guard let value = plist[key] as? T else { throw ParseError.missingField(key) }
            return value
        }

        name = try field("Name")
        uuid = try field("UUID")
        teamID = (try field("TeamIdentifier") as [String]).first ?? ""
        creationDate = try field("CreationDate")
        expirationDate = try field("ExpirationDate")
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }
}
