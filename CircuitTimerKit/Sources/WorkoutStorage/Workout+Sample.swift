import Foundation
import WorkoutDomain

extension Workout {
    /// The workout seeded on first launch, also used by previews and tests.
    ///
    /// The identifiers are permanent: once seeded they live in users' stores, and iCloud sync (CT-5)
    /// will merge copies seeded on different devices by them. They are random rather than sequential
    /// so they never collide with `UUIDGenerator.incrementing` in tests. Names are localized when the
    /// workout is seeded and are stored in that language.
    public static var sample: Workout {
        Workout(
            id: UUID(uuid: (0x38, 0x4B, 0x5A, 0xE9, 0xD6, 0xA4, 0x42, 0xAC, 0x96, 0x5A, 0x73, 0x30, 0xAA, 0xB7, 0xDE, 0xBE)),
            name: String(localized: "sample.name", bundle: .module),
            warmUp: [
                Stage(
                    id: UUID(uuid: (0x97, 0x59, 0x12, 0x45, 0x64, 0x1D, 0x4E, 0xE3, 0x85, 0xF2, 0x14, 0xE3, 0x1B, 0xD1, 0xF3, 0x4E)),
                    name: String(localized: "sample.stage.jumpingJacks", bundle: .module),
                    duration: .seconds(60),
                    intensity: .work
                ),
                Stage(
                    id: UUID(uuid: (0xE3, 0x07, 0x35, 0x5F, 0xB7, 0x04, 0x4A, 0x69, 0x8E, 0x30, 0x6B, 0x6E, 0x90, 0x97, 0xE8, 0x69)),
                    name: String(localized: "sample.stage.armCircles", bundle: .module),
                    duration: .seconds(30),
                    intensity: .rest
                ),
            ],
            training: [
                Stage(
                    id: UUID(uuid: (0x37, 0xE3, 0xFA, 0xF1, 0xE1, 0x13, 0x4A, 0xAD, 0xB2, 0x2C, 0x96, 0x02, 0x5A, 0xB1, 0xFB, 0x05)),
                    name: String(localized: "sample.stage.burpees", bundle: .module),
                    duration: .seconds(40),
                    intensity: .work
                ),
                Stage(
                    id: UUID(uuid: (0xC9, 0x8D, 0xD5, 0x65, 0x57, 0xEA, 0x46, 0x92, 0xAF, 0xC9, 0x11, 0x72, 0x07, 0xFB, 0xE6, 0xD5)),
                    name: String(localized: "sample.stage.rest", bundle: .module),
                    duration: .seconds(20),
                    intensity: .rest
                ),
                Stage(
                    id: UUID(uuid: (0x7D, 0x34, 0x78, 0x6F, 0x64, 0x08, 0x43, 0x2B, 0xBD, 0x21, 0x61, 0xE4, 0xE5, 0x4D, 0x45, 0x89)),
                    name: String(localized: "sample.stage.squats", bundle: .module),
                    duration: .seconds(40),
                    intensity: .work
                ),
                Stage(
                    id: UUID(uuid: (0x80, 0x35, 0xAD, 0x73, 0xBF, 0xD9, 0x4C, 0x09, 0xB3, 0x45, 0xC9, 0x24, 0xDA, 0x0F, 0x48, 0x6C)),
                    name: String(localized: "sample.stage.rest", bundle: .module),
                    duration: .seconds(20),
                    intensity: .rest
                ),
            ],
            trainingRounds: 3,
            coolDown: [
                Stage(
                    id: UUID(uuid: (0x8B, 0x58, 0xB6, 0x9C, 0x89, 0x93, 0x43, 0xB1, 0xBA, 0xB8, 0x3F, 0x95, 0x1C, 0x00, 0xAD, 0x6B)),
                    name: String(localized: "sample.stage.stretching", bundle: .module),
                    duration: .seconds(120),
                    intensity: .rest
                ),
            ],
            pauseAfterWarmUp: true
        )
    }
}
