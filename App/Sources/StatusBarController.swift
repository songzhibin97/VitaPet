import AppKit
import ChatUI
import Localization
import RenderEngine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct PomodoroMenuState {
        let startEnabled: Bool
        let pauseTitle: String
        let pauseEnabled: Bool
        let resetEnabled: Bool
        let skipEnabled: Bool
    }

    private let chatController: ChatWindowController
    private let isPetVisible: @MainActor () -> Bool
    private let togglePetVisibilityAction: @MainActor () -> Void
    private let currentPetSize: @MainActor () -> CGFloat
    private let currentMoodLevel: @MainActor () -> PetMood.MoodLevel
    private let resizePetsAction: @MainActor (CGFloat) -> Void
    private let canAddPet: @MainActor () -> Bool
    private let addPetAction: @MainActor () -> Void
    private let removePetAction: @MainActor (UUID) -> Void
    private let listPets: @MainActor () -> [(id: UUID, name: String)]
    private let debugTriggerAnimation: @MainActor (String) -> Void
    private let debugTriggerBehavior: @MainActor (String) -> Void
    private let debugListBehaviors: @MainActor () -> [String]
    private let debugTriggerInteraction: @MainActor () -> Void
    private let pomodoroMenuState: @MainActor () -> PomodoroMenuState
    private let startPomodoroAction: @MainActor () -> Void
    private let pauseOrResumePomodoroAction: @MainActor () -> Void
    private let resetPomodoroAction: @MainActor () -> Void
    private let skipPomodoroAction: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let addPetMenuItem = NSMenuItem()
    private let toggleMenuItem = NSMenuItem()
    private let miniGamesMenuItem = NSMenuItem(title: "小游戏", action: nil, keyEquivalent: "")
    private let pomodoroMenuItem = NSMenuItem(title: "番茄钟", action: nil, keyEquivalent: "")
    private let petSizeMenuItem = NSMenuItem(title: L10n.menuPetSize, action: nil, keyEquivalent: "")
    var onStartGame: ((String) -> Void)?
    var availableMiniGames: (() -> [String])?
    private var petSizeOptions: [(title: String, size: CGFloat)] {
        [
            (L10n.menuSizeSmall, 48),
            (L10n.menuSizeMedium, 72),
            (L10n.menuSizeLarge, 96),
            (L10n.menuSizeExtraLarge, 128)
        ]
    }

    init(
        chatController: ChatWindowController,
        isPetVisible: @escaping @MainActor () -> Bool,
        togglePetVisibility: @escaping @MainActor () -> Void,
        currentPetSize: @escaping @MainActor () -> CGFloat,
        currentMoodLevel: @escaping @MainActor () -> PetMood.MoodLevel,
        resizePets: @escaping @MainActor (CGFloat) -> Void,
        canAddPet: @escaping @MainActor () -> Bool,
        addPet: @escaping @MainActor () -> Void,
        removePet: @escaping @MainActor (UUID) -> Void,
        listPets: @escaping @MainActor () -> [(id: UUID, name: String)],
        pomodoroMenuState: @escaping @MainActor () -> PomodoroMenuState = {
            PomodoroMenuState(
                startEnabled: true,
                pauseTitle: "暂停",
                pauseEnabled: false,
                resetEnabled: false,
                skipEnabled: false
            )
        },
        startPomodoro: @escaping @MainActor () -> Void = {},
        pauseOrResumePomodoro: @escaping @MainActor () -> Void = {},
        resetPomodoro: @escaping @MainActor () -> Void = {},
        skipPomodoro: @escaping @MainActor () -> Void = {},
        debugTriggerAnimation: @escaping @MainActor (String) -> Void = { _ in },
        debugTriggerBehavior: @escaping @MainActor (String) -> Void = { _ in },
        debugListBehaviors: @escaping @MainActor () -> [String] = { [] },
        debugTriggerInteraction: @escaping @MainActor () -> Void = {}
    ) {
        self.chatController = chatController
        self.isPetVisible = isPetVisible
        self.togglePetVisibilityAction = togglePetVisibility
        self.currentPetSize = currentPetSize
        self.currentMoodLevel = currentMoodLevel
        self.resizePetsAction = resizePets
        self.canAddPet = canAddPet
        self.addPetAction = addPet
        self.removePetAction = removePet
        self.listPets = listPets
        self.pomodoroMenuState = pomodoroMenuState
        self.startPomodoroAction = startPomodoro
        self.pauseOrResumePomodoroAction = pauseOrResumePomodoro
        self.resetPomodoroAction = resetPomodoro
        self.skipPomodoroAction = skipPomodoro
        self.debugTriggerAnimation = debugTriggerAnimation
        self.debugTriggerBehavior = debugTriggerBehavior
        self.debugListBehaviors = debugListBehaviors
        self.debugTriggerInteraction = debugTriggerInteraction
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        configureStatusItem()
        configureMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateToggleTitle()
        updatePetSizeMenuState()
        addPetMenuItem.isEnabled = canAddPet()
        updateRemovePetMenu(in: menu)
        updateMiniGamesMenu(in: menu)
        updatePomodoroMenu()
        #if DEBUG
        updateDebugMenu(in: menu)
        #endif
        refreshMoodTooltip()
    }

    @objc
    private func openChat() {
        chatController.showChat()
    }

    @objc
    private func openSettings() {
        chatController.showSettings()
    }

    @objc
    private func openActivityLog() {
        chatController.showActivityLog()
    }

    @objc
    private func openStatistics() {
        chatController.showStatistics()
    }

    @objc
    private func togglePetVisibility() {
        togglePetVisibilityAction()
        updateToggleTitle()
    }

    @objc
    private func addPet() {
        addPetAction()
        addPetMenuItem.isEnabled = canAddPet()
    }

    @objc
    private func resizePet(_ sender: NSMenuItem) {
        resizePetsAction(CGFloat(sender.tag))
        updatePetSizeMenuState()
    }

    @objc
    private func terminate() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        if let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "VitaPet")
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "VitaPet") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "🐱"
        }

        button.toolTip = tooltip(for: currentMoodLevel())
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        addMenuItem(to: menu, title: L10n.menuChat, symbolName: "bubble.left", action: #selector(openChat))
        addMenuItem(to: menu, title: L10n.menuSettings, symbolName: "gearshape", action: #selector(openSettings), keyEquivalent: ",")
        addMenuItem(to: menu, title: L10n.menuActivityLog, symbolName: "list.bullet.rectangle", action: #selector(openActivityLog))
        addMenuItem(to: menu, title: "数据统计", symbolName: "chart.bar", action: #selector(openStatistics))

        menu.addItem(.separator())

        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(togglePetVisibility)
        menu.addItem(toggleMenuItem)

        addPetMenuItem.title = L10n.menuAddPet
        addPetMenuItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        addPetMenuItem.target = self
        addPetMenuItem.action = #selector(addPet)
        menu.addItem(addPetMenuItem)

        let removePetItem = NSMenuItem(title: L10n.menuRemovePet, action: nil, keyEquivalent: "")
        removePetItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
        removePetItem.submenu = NSMenu(title: L10n.menuRemovePet)
        removePetItem.tag = 999
        menu.addItem(removePetItem)

        miniGamesMenuItem.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        miniGamesMenuItem.submenu = NSMenu(title: "小游戏")
        miniGamesMenuItem.tag = 997
        menu.addItem(miniGamesMenuItem)

        pomodoroMenuItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        pomodoroMenuItem.submenu = makePomodoroMenu()
        pomodoroMenuItem.tag = 996
        menu.addItem(pomodoroMenuItem)

        petSizeMenuItem.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        petSizeMenuItem.submenu = makePetSizeMenu()
        menu.addItem(petSizeMenuItem)

        #if DEBUG
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: nil)
        debugItem.submenu = makeDebugMenu()
        debugItem.tag = 998
        menu.addItem(debugItem)
        #endif

        menu.addItem(.separator())

        addMenuItem(to: menu, title: L10n.menuQuit, symbolName: "power", action: #selector(terminate), keyEquivalent: "q")

        statusItem.menu = menu
        updateToggleTitle()
        refreshMoodTooltip()
    }

    private func updateMiniGamesMenu(in menu: NSMenu) {
        guard let gameItem = menu.items.first(where: { $0.tag == 997 }) else { return }

        let submenu = NSMenu(title: "小游戏")
        let games = availableMiniGames?() ?? []

        if games.isEmpty {
            let item = NSMenuItem(title: "暂无可用小游戏", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            gameItem.isEnabled = false
        } else {
            for game in games {
                let item = NSMenuItem(title: game, action: #selector(startMiniGame(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = game
                submenu.addItem(item)
            }
            gameItem.isEnabled = true
        }

        gameItem.submenu = submenu
    }

    private func makePomodoroMenu() -> NSMenu {
        let menu = NSMenu(title: "🍅 番茄钟")
        menu.addItem(NSMenuItem(title: "开始", action: #selector(startPomodoro), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "暂停", action: #selector(pauseOrResumePomodoro), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重置", action: #selector(resetPomodoro), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "跳过", action: #selector(skipPomodoro), keyEquivalent: ""))

        for item in menu.items {
            item.target = self
        }

        return menu
    }

    func refreshPomodoroMenuState() {
        updatePomodoroMenu()
    }

    private func updatePomodoroMenu() {
        guard let submenu = pomodoroMenuItem.submenu else {
            return
        }

        let state = pomodoroMenuState()
        submenu.items[safe: 0]?.isEnabled = state.startEnabled
        submenu.items[safe: 1]?.title = state.pauseTitle
        submenu.items[safe: 1]?.isEnabled = state.pauseEnabled
        submenu.items[safe: 2]?.isEnabled = state.resetEnabled
        submenu.items[safe: 3]?.isEnabled = state.skipEnabled
    }

    func refreshMoodTooltip() {
        statusItem.button?.toolTip = tooltip(for: currentMoodLevel())
    }

    private func updateToggleTitle() {
        toggleMenuItem.title = isPetVisible() ? L10n.menuHidePet : L10n.menuShowPet
        toggleMenuItem.image = NSImage(systemSymbolName: isPetVisible() ? "eye.slash" : "eye", accessibilityDescription: nil)
    }

    private func makePetSizeMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.menuPetSize)

        for option in petSizeOptions {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(resizePet(_:)),
                keyEquivalent: ""
            )
            item.tag = Int(option.size)
            item.target = self
            menu.addItem(item)
        }

        return menu
    }

    private func updatePetSizeMenuState() {
        guard let submenu = petSizeMenuItem.submenu else {
            return
        }

        let currentSize = Int(currentPetSize().rounded())
        for item in submenu.items {
            item.state = item.tag == currentSize ? .on : .off
        }
    }

    private func updateRemovePetMenu(in menu: NSMenu) {
        guard let removePetItem = menu.items.first(where: { $0.tag == 999 }) else { return }
        let pets = listPets()
        let submenu = NSMenu(title: L10n.menuRemovePet)
        // Only allow removal if more than 1 pet
        if pets.count > 1 {
            for pet in pets {
                let item = NSMenuItem(title: pet.name, action: #selector(removePetMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pet.id
                submenu.addItem(item)
            }
        }
        removePetItem.submenu = submenu
        removePetItem.isEnabled = pets.count > 1
    }

    @objc
    private func removePetMenuAction(_ sender: NSMenuItem) {
        guard let petId = sender.representedObject as? UUID else { return }
        removePetAction(petId)
    }

    @objc
    private func startMiniGame(_ sender: NSMenuItem) {
        guard let game = sender.representedObject as? String else { return }
        onStartGame?(game)
    }

    @objc
    private func startPomodoro() {
        startPomodoroAction()
        updatePomodoroMenu()
    }

    @objc
    private func pauseOrResumePomodoro() {
        pauseOrResumePomodoroAction()
        updatePomodoroMenu()
    }

    @objc
    private func resetPomodoro() {
        resetPomodoroAction()
        updatePomodoroMenu()
    }

    @objc
    private func skipPomodoro() {
        skipPomodoroAction()
        updatePomodoroMenu()
    }

    #if DEBUG
    private func makeDebugMenu() -> NSMenu {
        NSMenu(title: "Debug")
    }

    private func updateDebugMenu(in menu: NSMenu) {
        guard let debugItem = menu.items.first(where: { $0.tag == 998 }) else { return }
        let submenu = NSMenu(title: "Debug")

        // ── Animations ──
        let animHeader = NSMenuItem(title: "Animations", action: nil, keyEquivalent: "")
        animHeader.isEnabled = false
        animHeader.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        submenu.addItem(animHeader)
        let playImage = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        for state in AnimationState.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let item = NSMenuItem(title: state.rawValue, action: #selector(debugAnimationAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = playImage
            item.representedObject = state.rawValue
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        // ── Behaviors ──
        let behaviorHeader = NSMenuItem(title: "Behaviors", action: nil, keyEquivalent: "")
        behaviorHeader.isEnabled = false
        behaviorHeader.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        submenu.addItem(behaviorHeader)
        let boltImage = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        for name in debugListBehaviors() {
            let item = NSMenuItem(title: name, action: #selector(debugBehaviorAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = boltImage
            item.representedObject = name
            submenu.addItem(item)
        }

        debugItem.submenu = submenu
    }

    @objc
    private func debugAnimationAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        debugTriggerAnimation(name)
    }

    @objc
    private func debugBehaviorAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        debugTriggerBehavior(name)
    }

    #endif

    private func addMenuItem(to menu: NSMenu, title: String, symbolName: String, action: Selector, keyEquivalent: String = "") {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func tooltip(for level: PetMood.MoodLevel) -> String {
        switch level {
        case .happy:
            return "😊 心情很好"
        case .normal:
            return "😐 心情平静"
        case .sad:
            return "😢 心情低落"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
