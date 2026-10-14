import AVFAudio
import Foundation
import UIKit

extension CueEngine {
    func observeSystem() {
        dispatchPrecondition(condition: .onQueue(queue))
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.post(.resignedActive)
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.post(.becameActive)
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
                self?.post(type == .began ? .interruptionBegan : .interruptionEnded)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
                self?.post(.routeChanged(note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? Int ?? 0))
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.post(.mediaServicesReset)
            },
            center.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.post(.voicesChanged)
            },
        ]
    }
}
