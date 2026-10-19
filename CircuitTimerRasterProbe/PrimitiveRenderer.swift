import DesignSystem
import SwiftUI
import UIKit

@MainActor
enum PrimitiveRenderer: String, CaseIterable {
    case coreGraphics, imageRenderer, drawHierarchy, layerRender

    struct Sample {
        let rounded: Bool
        let antialias: Bool
        let halfPixel: Bool

        var origin: CGPoint {
            let shift: CGFloat = halfPixel ? 0.5 / 3 : 0
            return CGPoint(x: 40 + shift, y: 709 + shift)
        }

        var path: Path {
            let bounds = CGRect(origin: .zero, size: CGSize(width: .token(size: .marker), height: .token(size: .marker)))
            return rounded
                ? RoundedRectangle(cornerRadius: .token(radius: .xs), style: .continuous).path(in: bounds)
                : Rectangle().path(in: bounds)
        }

        var key: String { "\(rounded ? "rounded" : "rectangle")-\(antialias ? "aa" : "noaa")-\(halfPixel ? "half" : "integer")" }
    }

    struct Capture {
        let image: CGImage
        let environment: [String: Any]
    }

    static let size = CGSize(width: 402, height: 874)
    static let scale: CGFloat = 3
    static var foreground: Color { .stage(.rest) }
    static var background: Color { .surface(.field) }

    func capture(_ sample: Sample, anchor: UIWindow) async throws -> Capture {
        switch self {
            case .coreGraphics:
                let context = try RasterProbe.bitmap(width: 1206, height: 2622)
                context.translateBy(x: 0, y: 2622)
                context.scaleBy(x: Self.scale, y: -Self.scale)
                context.setFillColor(try Self.resolved(Self.background))
                context.fill(CGRect(origin: .zero, size: Self.size))
                context.setAllowsAntialiasing(sample.antialias)
                context.setShouldAntialias(sample.antialias)
                context.translateBy(x: sample.origin.x, y: sample.origin.y)
                context.addPath(sample.path.cgPath)
                context.setFillColor(try Self.resolved(Self.foreground))
                context.fillPath()
                guard let image = context.makeImage() else { throw ProbeFailure("CoreGraphics produced no image") }
                return Capture(image: image, environment: [:])
            case .imageRenderer:
                let renderer = ImageRenderer(content: PrimitiveView(sample: sample))
                renderer.proposedSize = ProposedViewSize(Self.size)
                renderer.scale = Self.scale
                renderer.colorMode = .nonLinear
                guard let image = renderer.cgImage else { throw ProbeFailure("ImageRenderer produced no image") }
                return Capture(image: image, environment: [:])
            case .drawHierarchy, .layerRender:
                return try await mounted(sample, anchor: anchor)
        }
    }

    private func mounted(_ sample: Sample, anchor: UIWindow) async throws -> Capture {
        guard let scene = anchor.windowScene else { throw ProbeFailure("No window scene") }
        let controller = UIHostingController(rootView: PrimitiveView(sample: sample))
        controller.traitOverrides.displayGamut = .SRGB
        controller.traitOverrides.displayScale = Self.scale
        controller.traitOverrides.userInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            anchor.makeKey()
        }
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = .dark
        window.traitOverrides.displayGamut = .SRGB
        window.traitOverrides.displayScale = Self.scale
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await RasterProbe.runLoopTurn()
        try Task.checkCancellation()
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.preferredRange = .standard
        var succeeded = true
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { context in
            if self == .drawHierarchy {
                succeeded = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            } else {
                window.layer.render(in: context.cgContext)
            }
        }
        guard succeeded, let raster = image.cgImage else { throw ProbeFailure("\(rawValue) failed to capture") }
        let frame = controller.view.frame
        let bounds = controller.view.bounds
        let transform = controller.view.transform
        return Capture(image: raster, environment: [
            "viewFrame": [frame.minX, frame.minY, frame.width, frame.height].map { String(Double($0).bitPattern, radix: 16) },
            "viewBounds": [bounds.minX, bounds.minY, bounds.width, bounds.height].map { String(Double($0).bitPattern, radix: 16) },
            "viewTransform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                .map { String(Double($0).bitPattern, radix: 16) },
            "layerContentsScale": controller.view.layer.contentsScale,
            "windowGamut": window.traitCollection.displayGamut.rawValue,
            "rootGamut": controller.traitCollection.displayGamut.rawValue
        ])
    }

    static func resolved(_ color: Color) throws -> CGColor {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        let resolved = color.resolve(in: environment).cgColor
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.converted(to: space, intent: .defaultIntent, options: nil) else {
            throw ProbeFailure("Could not resolve a DesignSystem token to sRGB")
        }
        return converted
    }
}

private struct PrimitiveView: View {
    let sample: PrimitiveRenderer.Sample

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.surface(.field))
            FixedPath(value: sample.path)
                .fill(.stage(.rest), style: FillStyle(antialiased: sample.antialias))
                .frame(width: .token(size: .marker), height: .token(size: .marker))
                .offset(x: sample.origin.x, y: sample.origin.y)
        }
        .frame(width: PrimitiveRenderer.size.width, height: PrimitiveRenderer.size.height, alignment: .topLeading)
        .environment(\.displayScale, PrimitiveRenderer.scale)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

private struct FixedPath: Shape {
    let value: Path
    func path(in rect: CGRect) -> Path { value }
}
