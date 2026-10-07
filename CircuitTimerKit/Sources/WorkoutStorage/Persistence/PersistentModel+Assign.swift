import SwiftData

extension PersistentModel {
    /// Writes only real changes, so saving an unchanged workout leaves its records untouched
    /// and gives sync nothing to upload (CT-5).
    func assign<Value: Equatable>(_ value: Value, to keyPath: ReferenceWritableKeyPath<Self, Value>) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
