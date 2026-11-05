import Foundation

/// The version and the limits of the wire between the iPhone app and the watch app.
///
/// Until the first build that leaves internal testing (external TestFlight or the App Store) only internal testers
/// install either side, so version 1 may change freely. From that build version 1 only gains optional fields; a
/// required field or a new enum case other than an `UnavailableReason` raises `version`.
public enum WatchLinkSchema {
    public static let version = 1
    /// The largest encoded envelope the iPhone sends. WatchConnectivity documents no limit; this one is an assumption
    /// checked on a device.
    public static let envelopeLimit = 60_000
    /// The room a catalog leaves for a running workout: the catalog is cut to `envelopeLimit` less this, so its cut
    /// does not change with each stage. A whole state is still checked against `envelopeLimit`.
    public static let runReserve = 8_192
    /// The single key of the application context; its value is the encoded `PhoneState`.
    static let contextKey = "ct.v"
}

/// One encoding for every message, so a digest computed by one side matches the bytes the other side stores.
enum WireCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder().decode(type, from: data)
    }

    /// The peer's version, read before anything else; `nil` when the data is not one of our envelopes, which the
    /// caller reports as an incompatible peer.
    static func schemaVersion(of data: Data) -> Int? {
        do {
            return try decoder().decode(SchemaProbe.self, from: data).schemaVersion
        } catch {
            return nil
        }
    }
}

private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}
