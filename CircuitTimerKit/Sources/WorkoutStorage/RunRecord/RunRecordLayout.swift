import CryptoKit
import Foundation
import os

enum RunRecordLayout {
    static let fileExtension = "json"

    /// The file of `sessionID`: the hex SHA-256 of the identifier, which is always a valid,
    /// fixed-length file name whatever characters the identifier holds.
    static func fileURL(in directory: URL, sessionID: String) -> URL {
        let name = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).\(fileExtension)", directoryHint: .notDirectory)
    }

    /// Whether `error` says the file is not there. Foundation reports it in several shapes
    /// depending on the call, so every one of them is accepted.
    static func isMissingFile(_ error: any Error) -> Bool {
        if let error = error as? CocoaError, [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return true
        }
        if let error = error as? POSIXError, error.code == .ENOENT {
            return true
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
    }
}

extension Logger {
    static let runRecord = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "RunRecord")
}
