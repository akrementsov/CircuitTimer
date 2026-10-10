import CoreText
import Foundation
import os

/// League Gothic ships in this module and is registered for the process on first use.
enum LeagueGothic {
    static let postScriptName = "LeagueGothic-Regular"

    /// Registers the font once; false when it cannot be drawn, so callers use a system face instead.
    static let isAvailable: Bool = {
        // `.process` resources lose their folders, so the font is looked up at the bundle's top level.
        guard let url = Bundle.module.url(forResource: "LeagueGothic-Regular-VariableFont_wdth", withExtension: "ttf") else {
            Logger.designSystem.error("League Gothic is missing from the DesignSystem bundle")
            return false
        }

        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            guard let error = error?.takeRetainedValue() else {
                Logger.designSystem.error("Failed to register League Gothic without an error")
                return false
            }
            if CTFontManagerError(rawValue: CFErrorGetCode(error)) == .alreadyRegistered {
                return true
            }
            Logger.designSystem.error("Failed to register League Gothic: \(String(reflecting: error), privacy: .public)")
            return false
        }
        return true
    }()
}
