import Foundation

struct Note {
    let frequency: Double
    let seconds: Double
}

func wave(_ notes: [Note]) -> Data {
    let sampleRate = 44_100
    var samples = Data()
    for note in notes {
        let count = Int((note.seconds * Double(sampleRate)).rounded())
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let envelope = min(1, time / 0.005, (note.seconds - time) / 0.030)
            let value = Int16((sin(2 * .pi * note.frequency * time) * envelope * 0.7 * Double(Int16.max)).rounded())
            append(value, to: &samples)
        }
    }
    var data = Data("RIFF".utf8)
    append(UInt32(36 + samples.count), to: &data)
    data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16), to: &data)
    append(UInt16(1), to: &data)
    append(UInt16(1), to: &data)
    append(UInt32(sampleRate), to: &data)
    append(UInt32(sampleRate * 2), to: &data)
    append(UInt16(2), to: &data)
    append(UInt16(16), to: &data)
    data.append(Data("data".utf8))
    append(UInt32(samples.count), to: &data)
    data.append(samples)
    return data
}

func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

let destination = URL(fileURLWithPath: "CircuitTimerKit/Sources/WorkoutTimerFeature/Resources", isDirectory: true)
let tones: [(String, [Note])] = [
    ("countdown", [Note(frequency: 880, seconds: 0.150)]),
    ("stage-start", [Note(frequency: 1_320, seconds: 0.350)]),
    ("finish", [
        Note(frequency: 1_046.502261, seconds: 0.150),
        Note(frequency: 1_318.510228, seconds: 0.150),
        Note(frequency: 1_567.981744, seconds: 0.400),
    ]),
]

do {
    for (name, notes) in tones {
        try wave(notes).write(to: destination.appendingPathComponent("cue-\(name).wav"), options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("Generating cue tones failed: \(error)\n".utf8))
    exit(1)
}
