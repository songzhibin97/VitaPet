import Foundation

public struct PetIdentity: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var spritePack: String
    public var size: Double
    public var gender: String
    public var age: String
    public var personality: String
    public var hobbies: String
    public var positionX: Double
    public var positionY: Double
    public var happiness: Int

    // Instance-level overrides (nil = use template default)
    public var customLanguage: [String: [String]]?
    public var soundEnabled: Bool?
    public var soundVolume: Float?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case spritePack
        case size
        case gender
        case age
        case personality
        case hobbies
        case positionX
        case positionY
        case happiness
        case customLanguage
        case soundEnabled
        case soundVolume
    }

    public init(
        id: UUID,
        name: String,
        spritePack: String,
        size: Double,
        gender: String = "neutral",
        age: String = "",
        personality: String = "",
        hobbies: String = "",
        positionX: Double,
        positionY: Double,
        happiness: Int = 50
    ) {
        self.id = id
        self.name = name
        self.spritePack = spritePack
        self.size = size
        self.gender = gender
        self.age = age
        self.personality = personality
        self.hobbies = hobbies
        self.positionX = positionX
        self.positionY = positionY
        self.happiness = max(0, min(100, happiness))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        spritePack = try container.decode(String.self, forKey: .spritePack)
        size = try container.decode(Double.self, forKey: .size)
        gender = try container.decodeIfPresent(String.self, forKey: .gender) ?? "neutral"
        age = try container.decodeIfPresent(String.self, forKey: .age) ?? ""
        personality = try container.decodeIfPresent(String.self, forKey: .personality) ?? ""
        hobbies = try container.decodeIfPresent(String.self, forKey: .hobbies) ?? ""
        positionX = try container.decode(Double.self, forKey: .positionX)
        positionY = try container.decode(Double.self, forKey: .positionY)
        happiness = max(0, min(100, try container.decodeIfPresent(Int.self, forKey: .happiness) ?? 50))
        customLanguage = try container.decodeIfPresent([String: [String]].self, forKey: .customLanguage)
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled)
        soundVolume = try container.decodeIfPresent(Float.self, forKey: .soundVolume)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(spritePack, forKey: .spritePack)
        try container.encode(size, forKey: .size)
        try container.encode(gender, forKey: .gender)
        try container.encode(age, forKey: .age)
        try container.encode(personality, forKey: .personality)
        try container.encode(hobbies, forKey: .hobbies)
        try container.encode(positionX, forKey: .positionX)
        try container.encode(positionY, forKey: .positionY)
        try container.encode(happiness, forKey: .happiness)
        try container.encodeIfPresent(customLanguage, forKey: .customLanguage)
        try container.encodeIfPresent(soundEnabled, forKey: .soundEnabled)
        try container.encodeIfPresent(soundVolume, forKey: .soundVolume)
    }

    public static func defaultPet() -> PetIdentity {
        PetIdentity(
            id: UUID(),
            name: "Cat",
            spritePack: "PixelCat",
            size: 96,
            positionX: 120,
            positionY: 120
        )
    }
}
