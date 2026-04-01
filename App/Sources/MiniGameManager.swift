import AppKit

@MainActor
protocol MiniGame: AnyObject {
    var name: String { get }
    var minPets: Int { get }
    var maxPets: Int { get }
    func start(pets: [PetWindowController], onComplete: @escaping () -> Void)
    func stop()
}

@MainActor
final class MiniGameManager {
    private var currentGame: (any MiniGame)?
    private var getPetControllers: (() -> [PetWindowController])?
    private var onGameStateChanged: ((Bool) -> Void)?
    var onGameStarted: ((String, Int) -> Void)?

    var isPlaying: Bool { currentGame != nil }

    func configure(
        getPetControllers: @escaping () -> [PetWindowController],
        onGameStateChanged: @escaping (Bool) -> Void
    ) {
        self.getPetControllers = getPetControllers
        self.onGameStateChanged = onGameStateChanged
    }

    func startGame(_ game: any MiniGame) {
        guard !isPlaying else { return }
        guard let controllers = getPetControllers?(), controllers.count >= game.minPets else { return }

        let pets = Array(controllers.prefix(game.maxPets))
        currentGame = game
        onGameStateChanged?(true)

        for pet in pets {
            pet.clearDesktopBehavior()
        }

        onGameStarted?(game.name, pets.count)
        game.start(pets: pets) { [weak self] in
            self?.endCurrentGame()
        }
    }

    func startGame(named name: String) {
        guard let game = availableGames().first(where: { $0.name == name }) else {
            return
        }
        startGame(game)
    }

    func endCurrentGame() {
        currentGame?.stop()
        currentGame = nil
        onGameStateChanged?(false)
    }

    func availableGames() -> [any MiniGame] {
        let petCount = getPetControllers?().count ?? 0
        let all: [any MiniGame] = [
            RockPaperScissorsGame(),
            RaceGame(),
            HideAndSeekGame(),
            CatchGame()
        ]
        return all.filter { petCount >= $0.minPets }
    }
}

@MainActor
enum MiniGameSupport {
    static func mainScreenFrame() -> NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    static func clamp(origin: NSPoint, for pet: PetWindowController, in frame: NSRect) -> NSPoint {
        let size = pet.window?.frame.size ?? CGSize(width: pet.currentPetSize, height: pet.currentPetSize)
        let x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        let y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    static func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    static func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { block() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}
