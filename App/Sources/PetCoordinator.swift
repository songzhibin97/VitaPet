import AppKit
import AIEngine
import ChatUI
import EventBus
import Localization
import Persistence
import PluginRuntime
import RenderEngine
import SecurityLayer

/// Owns the petWindowControllers dictionary and all pet lifecycle / visibility methods.
/// Created by AppBootstrapper during bootstrap and held by AppDelegate.
@MainActor
final class PetCoordinator {

    // MARK: - Shared State (written by AppBootstrapper, read by all)
    var petWindowControllers: [UUID: PetWindowController] = [:]

    // Injected dependencies (set by AppBootstrapper after creation)
    weak var appDelegate: AppDelegate?

    // MARK: - Computed helpers

    var primaryPetController: PetWindowController? {
        appDelegate?.configManager?.config.pets.first.flatMap { petWindowControllers[$0.id] }
    }

    var isAnyPetVisible: Bool {
        petWindowControllers.values.contains { $0.isPetVisible }
    }

    var currentGlobalPetSize: CGFloat {
        primaryPetController?.currentPetSize ?? 96
    }

    // MARK: - Pet Visibility

    func togglePetVisibility() {
        if isAnyPetVisible {
            for controller in petWindowControllers.values {
                controller.hidePet()
            }
            return
        }

        for controller in petWindowControllers.values {
            controller.showPet()
        }
    }

    func resizePets(to size: CGFloat) {
        for controller in petWindowControllers.values {
            controller.resizePet(to: size)
        }
    }

    // MARK: - Sound Helpers

    func resolvedSoundEnabled(for pet: PetIdentity) -> Bool {
        pet.soundEnabled ?? SoundManager().isEnabled
    }

    func resolvedVolume(for pet: PetIdentity) -> Float {
        pet.soundVolume ?? SoundManager().volume
    }

    func applySoundOverrides(for pet: PetIdentity) {
        petWindowControllers[pet.id]?.soundManager?.applyRuntimeSettings(
            enabled: resolvedSoundEnabled(for: pet),
            volume: resolvedVolume(for: pet)
        )
    }

    // MARK: - Pet Lifecycle

    func createAndShowPetController(for pet: PetIdentity) {
        guard let appDelegate else { return }
        let controller = PetWindowController(
            petIdentity: pet,
            configManager: appDelegate.configManager,
            chatController: appDelegate.chatController,
            moodDidChange: { [weak appDelegate] in
                appDelegate?.statusBarController?.refreshMoodTooltip()
            }
        )
        controller.soundManager = SoundManager()
        controller.soundManager?.applyRuntimeSettings(
            enabled: resolvedSoundEnabled(for: pet),
            volume: resolvedVolume(for: pet)
        )
        controller.reloadCurrentSpritePackSounds()
        controller.windowDetector = { [weak self, weak appDelegate] in
            guard let self, let appDelegate else {
                return []
            }

            let ownWindowNumbers = Set(
                self.petWindowControllers.values
                    .compactMap { $0.window?.windowNumber }
                    .compactMap { Int($0) }
            )

            return appDelegate.windowDetector
                .detectWindows(excludingWindowNumbers: ownWindowNumbers)
                .map(\.appKitFrame)
        }
        controller.onMoodChange = { [weak appDelegate] petId, petName, happiness, delta, level in
            guard let databaseManager = appDelegate?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "moodChange",
                        payload: try AppDelegate.encodeMoodChangePayload(
                            MoodChangeEventPayload(
                                petId: petId,
                                petName: petName,
                                happiness: happiness,
                                delta: delta,
                                level: level
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record mood change: \(error.localizedDescription)")
                }
            }
        }
        controller.onBehaviorChange = { [weak appDelegate] petId, petName, state in
            guard let databaseManager = appDelegate?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petBehavior",
                        payload: try AppDelegate.encodePetBehaviorPayload(
                            PetBehaviorEventPayload(
                                petId: petId,
                                petName: petName,
                                state: state
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet behavior: \(error.localizedDescription)")
                }
            }
        }
        controller.onPetClick = { [weak appDelegate] petId, petName, type in
            guard let databaseManager = appDelegate?.databaseManager else {
                return
            }

            Task {
                do {
                    try await databaseManager.insertEvent(
                        source: "petClick",
                        payload: try AppDelegate.encodePetClickPayload(
                            PetClickEventPayload(
                                petId: petId,
                                petName: petName,
                                type: type
                            )
                        )
                    )
                } catch {
                    AppLogger.error("Failed to record pet click: \(error.localizedDescription)")
                }
            }
        }
        controller.behaviorWeightMultipliers = appDelegate.timeWeatherController.currentBehaviorMultipliers
        petWindowControllers[pet.id] = controller
        appDelegate.interactionManager?.register(id: pet.id, controller: controller)
        controller.setOtherPetPositionsProvider { [weak self, petId = pet.id] in
            self?.appDelegate?.interactionManager?.otherPetPositions(excluding: petId) ?? []
        }
        controller.showPet()
        controller.petScene.playAnimation(for: .idle)
        appDelegate.statusBarController.refreshMoodTooltip()
    }

    func addPet() {
        guard let appDelegate else { return }
        guard petWindowControllers.count < appDelegate.maximumPets else {
            return
        }

        let existingNames = Set(appDelegate.configManager.config.pets.map(\.name))
        var counter = petWindowControllers.count + 1
        var newName = "Pet \(counter)"
        while existingNames.contains(newName) {
            counter += 1
            newName = "Pet \(counter)"
        }

        let basePet = primaryPetController.map { controller in
            PetIdentity(
                id: UUID(),
                name: newName,
                spritePack: controller.currentSpritePackID,
                size: Double(controller.currentPetSize),
                positionX: Double((controller.window?.frame.origin.x ?? 120) + 36),
                positionY: Double((controller.window?.frame.origin.y ?? 120) + 36)
            )
        } ?? PetIdentity.defaultPet()

        let pet = basePet.positionX == 120 && basePet.positionY == 120 && petWindowControllers.isEmpty
            ? basePet
            : PetIdentity(
                id: basePet.id,
                name: basePet.name,
                spritePack: basePet.spritePack,
                size: basePet.size,
                positionX: basePet.positionX,
                positionY: basePet.positionY
            )

        do {
            try appDelegate.configManager.update { $0.pets.append(pet) }
        } catch {
            AppLogger.error("Failed to add pet: \(error.localizedDescription)")
            return
        }

        Task {
            await appDelegate.createSingleConversationIfNeeded(for: pet)
        }

        createAndShowPetController(for: pet)
        appDelegate.refreshChatIfOpen()
    }

    func removePet(id: UUID) {
        guard let appDelegate else { return }
        guard petWindowControllers.count > 1 else {
            return
        }

        petWindowControllers[id]?.closePet()
        petWindowControllers[id] = nil
        appDelegate.interactionManager?.unregister(id: id)

        do {
            try appDelegate.configManager.update { config in
                config.pets.removeAll { $0.id == id }
            }
        } catch {
            AppLogger.error("Failed to remove pet: \(error.localizedDescription)")
            return
        }

        // 清理对话：直接操作数据库 + 内存
        appDelegate.chatController.removePetConversations(petId: id)
        // 数据库层面也直接删除单聊（避免内存未加载时遗漏）
        Task {
            try? await appDelegate.databaseManager?.deleteConversation(id: "single_\(id.uuidString)")
            // 查询数据库中包含该宠物的群聊并清理
            if let conversations = try? await appDelegate.databaseManager?.fetchConversations() {
                for conv in conversations where conv.type == .group && conv.participantIds.contains(id) {
                    let remaining = conv.participantIds.filter { $0 != id }
                    if remaining.count <= 1 {
                        try? await appDelegate.databaseManager?.deleteConversation(id: conv.id)
                    } else {
                        try? await appDelegate.databaseManager?.updateConversationParticipantIds(id: conv.id, participantIds: remaining)
                    }
                }
            }
        }
        appDelegate.refreshChatIfOpen()
    }

    func updateBehaviorMultipliers() {
        guard let appDelegate else { return }
        let multipliers = appDelegate.timeWeatherController.currentBehaviorMultipliers
        for controller in petWindowControllers.values {
            controller.behaviorWeightMultipliers = multipliers
        }
    }
}
