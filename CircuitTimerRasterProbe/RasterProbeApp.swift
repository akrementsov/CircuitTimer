import DesignSystem
import os
import SwiftUI
import UIKit

// Temporary investigation app. It has no feature stores or production side effects.
@main
struct RasterProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeLauncher().preferredColorScheme(.dark) }
    }
}

private struct ProbeLauncher: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}
}

@MainActor
private final class ProbeController: UIViewController {
    private var started = false
    private let status = UIHostingController(rootView: ProbeMessage(title: "Raster probe"))

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(status)
        status.view.frame = view.bounds
        status.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(status.view)
        status.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started, let window = view.window else { return }
        started = true
        Task {
            do {
                try await RasterProbe.run(anchor: window)
                status.rootView = ProbeMessage(title: "Probe complete")
            } catch is CancellationError {
                status.rootView = ProbeMessage(title: "Probe cancelled")
            } catch {
                let logger = Logger(subsystem: "CircuitTimerRasterProbe", category: "Capture")
                logger.error("Probe failed: \(String(reflecting: error), privacy: .public)")
                status.rootView = ProbeMessage(title: "Probe failed")
                do {
                    try String(reflecting: error).write(
                        to: RasterProbe.directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8
                    )
                } catch {
                    logger.error("Could not save probe error: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
    }
}

private struct ProbeMessage: View {
    let title: String

    var body: some View {
        ZStack {
            Rectangle().fill(.surface(.screen))
            Text(title).font(.token(.body)).foregroundStyle(.text(.primary))
        }
    }
}
