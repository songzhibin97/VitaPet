public actor PetMood {
    public enum MoodLevel: String, Sendable {
        case happy
        case normal
        case sad
    }

    public private(set) var happiness: Int

    public init(happiness: Int = 50) {
        self.happiness = Self.clamp(happiness)
    }

    public func adjust(by delta: Int) {
        happiness = Self.clamp(happiness + delta)
    }

    public var level: MoodLevel {
        Self.level(for: happiness)
    }

    public nonisolated static func level(for happiness: Int) -> MoodLevel {
        let clampedHappiness = clamp(happiness)
        if clampedHappiness > 70 {
            return .happy
        }
        if clampedHappiness < 30 {
            return .sad
        }
        return .normal
    }

    public nonisolated static func clamp(_ happiness: Int) -> Int {
        max(0, min(100, happiness))
    }
}
