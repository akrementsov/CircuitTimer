import Foundation

enum RunRecordLayout {
    static func fileURL(in directory: URL) -> URL {
        directory.appending(path: "WorkoutRun.json", directoryHint: .notDirectory)
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
