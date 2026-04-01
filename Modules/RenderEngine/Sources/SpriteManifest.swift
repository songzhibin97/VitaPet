public struct SpriteManifest: Codable, Sendable {
    public let name: String
    public let version: String
    public let states: [String: StateAnimation]
    public let sounds: [String: String]?
    public let language: [String: [String]]?

    public init(
        name: String,
        version: String,
        states: [String: StateAnimation],
        sounds: [String: String]? = nil,
        language: [String: [String]]? = nil
    ) {
        self.name = name
        self.version = version
        self.states = states
        self.sounds = sounds
        self.language = language
    }

    public struct StateAnimation: Codable, Sendable {
        public let frames: [String]
        public let frameInterval: Double
        public let loop: Bool

        public init(frames: [String], frameInterval: Double, loop: Bool) {
            self.frames = frames
            self.frameInterval = frameInterval
            self.loop = loop
        }
    }
}
