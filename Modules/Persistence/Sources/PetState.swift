public struct PetState: Sendable {
    public let petId: String
    public let animationState: String
    public let positionX: Double
    public let positionY: Double
    public let screenId: String

    public init(
        petId: String,
        animationState: String,
        positionX: Double,
        positionY: Double,
        screenId: String
    ) {
        self.petId = petId
        self.animationState = animationState
        self.positionX = positionX
        self.positionY = positionY
        self.screenId = screenId
    }
}
