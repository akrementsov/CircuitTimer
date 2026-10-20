import Foundation
import SnapshotTesting
import UIKit

@MainActor
enum SnapshotViewport {
    static let size = CGSize(width: 402, height: 874)
    static let safeArea = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    static let scale: CGFloat = 3

    static var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func validateRuntime(_ version: OperatingSystemVersion) throws {
        guard version.majorVersion == 27, version.minorVersion == 0, version.patchVersion == 0 else {
            throw SnapshotCaptureFailure("Snapshots require the iOS 27.0 simulator.")
        }
    }

    static func validateScene(size: CGSize, scale: CGFloat) throws {
        guard size == Self.size, scale == Self.scale else {
            throw SnapshotCaptureFailure("Snapshots require a 402×874 pt scene at 3x.")
        }
    }

    static func validateSafeArea(_ insets: UIEdgeInsets) throws {
        guard insets == safeArea else {
            throw SnapshotCaptureFailure("Snapshots require safe area insets of 62/34 pt; got \(insets).")
        }
    }

    static func validateRaster(_ raster: CGImage?) throws {
        guard let raster, raster.width == Int(pixelSize.width), raster.height == Int(pixelSize.height) else {
            throw SnapshotCaptureFailure("The snapshot raster must be 1206×2622 px.")
        }
    }

    static var configuration: ViewImageConfig {
        ViewImageConfig(
            safeArea: safeArea,
            size: size,
            traits: UITraitCollection(userInterfaceIdiom: .phone).modifyingTraits {
                $0.horizontalSizeClass = .compact
                $0.verticalSizeClass = .regular
                $0.displayScale = scale
            }
        )
    }
}
