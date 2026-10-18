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
