import AppKit
import Foundation
import Localization
import RenderEngine

enum PetInteractionType: String, Sendable, CaseIterable {
    // Pair
    case chase
    case greet
    case chat
    case syncDance

    // Solo
    case soloPlay
    case soloGroom
    case soloExplore

    // Trio
    case triChase
    case triChat
    case triPlay

    // Group
    case groupCelebrate
    case groupSleep
    case groupFollow
}

@MainActor
final class PetInteractionManager {
    private var pets: [UUID: PetWindowController] = [:]
    var onInteractionTriggered: ((String, [String]) -> Void)?

    private let soloPlayBubbles = ["自己玩也开心~"]
    private let soloGroomBubbles = ["该洗澡啦~"]
    private let soloExploreBubbles = ["出去逛逛~"]
    private let spectatorBubbles = ["👀", "哇！", "加油！", "好厉害！"]
    private let trioChatBubbles = ["我也想说！", "然后呢？", "真的吗？", "哈哈哈"]
    private let groupCelebrateBubbles = ["🎉", "太棒了！"]
    private let groupSleepBubbles = ["💤", "晚安~"]
    private let groupFollowBubbles = ["跟上！", "等等我！"]

    func register(id: UUID, controller: PetWindowController) {
        pets[id] = controller
    }

    func unregister(id: UUID) {
        pets[id] = nil
    }

    /// 获取指定宠物的窗口中心位置
    func petPosition(for id: UUID) -> NSPoint? {
        guard let controller = pets[id],
              let frame = controller.window?.frame else {
            return nil
        }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// 找到距离指定宠物最近的另一只宠物
    func nearestPet(from id: UUID) -> (id: UUID, position: NSPoint, distance: CGFloat)? {
        guard let myPos = petPosition(for: id) else {
            return nil
        }

        var nearest: (id: UUID, position: NSPoint, distance: CGFloat)?
        for (otherId, _) in pets where otherId != id {
            guard let otherPos = petPosition(for: otherId) else {
                continue
            }

            let dx = myPos.x - otherPos.x
            let dy = myPos.y - otherPos.y
            let distance = sqrt(dx * dx + dy * dy)
            if nearest == nil || distance < nearest!.distance {
                nearest = (otherId, otherPos, distance)
            }
        }

        return nearest
    }

    /// 返回所有宠物位置
    func allPetPositions() -> [(id: UUID, position: NSPoint)] {
        pets.compactMap { id, _ in
            guard let position = petPosition(for: id) else {
                return nil
            }
            return (id, position)
        }
    }

    func otherPetPositions(excluding id: UUID) -> [NSPoint] {
        pets.compactMap { otherId, controller in
            guard otherId != id, let frame = controller.window?.frame else { return nil }
            return NSPoint(x: frame.midX, y: frame.midY)
        }
    }

    /// 检查是否有足够宠物进行互动
    var canInteract: Bool {
        pets.count >= 1
    }

    func availablePets() -> [UUID] {
        pets.compactMap { id, controller in
            controller.isAvailableForInteraction ? (id, controller) : nil
        }
        .sorted { lhs, rhs in
            interactionPriority(for: lhs.1) < interactionPriority(for: rhs.1)
        }
        .map(\.0)
    }

    func randomSingle() -> UUID? {
        availablePets().randomElement()
    }

    /// 随机选择两只可互动宠物
    func randomPair() -> (id1: UUID, id2: UUID)? {
        randomPair(from: availablePets())
    }

    func randomTrio() -> (UUID, UUID, UUID)? {
        let ids = availablePets()
        guard ids.count >= 3 else {
            return nil
        }

        let shuffled = ids.shuffled()
        return (shuffled[0], shuffled[1], shuffled[2])
    }

    /// 获取宠物控制器
    func controller(for id: UUID) -> PetWindowController? {
        pets[id]
    }

    /// 执行一次随机互动
    func triggerRandomInteraction() {
        let available = availablePets()
        let interaction: (type: PetInteractionType, petNames: [String])?

        switch available.count {
        case 0:
            return
        case 1:
            interaction = triggerSoloInteraction(available[0])
        case 2:
            interaction = triggerPairInteraction(available[0], available[1])
        default:
            let roll = Double.random(in: 0...1)
            if roll < 0.4, let pair = randomPair(from: available) {
                interaction = triggerPairInteraction(pair.id1, pair.id2)
            } else if roll < 0.7, let trio = randomTrio(from: available) {
                interaction = triggerTrioInteraction(trio.0, trio.1, trio.2)
            } else {
                interaction = triggerGroupInteraction(available)
            }
        }

        if let interaction {
            onInteractionTriggered?(interaction.type.rawValue, interaction.petNames)
        }
    }

    /// 执行指定类型的互动
    func executeInteraction(pet1: UUID, pet2: UUID, type: PetInteractionType) {
        guard let c1 = controller(for: pet1),
              let c2 = controller(for: pet2) else {
            return
        }

        guard c1.isAvailableForInteraction, c2.isAvailableForInteraction else {
            return
        }

        switch type {
        case .chase:
            executeChase(chaser: c1, target: c2)
        case .greet:
            executeGreet(pet1: c1, pet2: c2)
        case .chat:
            executeChat(pet1: c1, pet2: c2)
        case .syncDance:
            executeSyncDance(pets: [c1, c2])
        default:
            return
        }
    }

    @discardableResult
    func triggerSoloInteraction(_ petID: UUID) -> (type: PetInteractionType, petNames: [String])? {
        guard let pet = controller(for: petID), pet.isAvailableForInteraction else {
            return nil
        }

        let types: [PetInteractionType] = [.soloPlay, .soloGroom, .soloExplore]
        let type = types.randomElement() ?? .soloPlay
        switch type {
        case .soloPlay:
            executeSoloPlay(pet: pet)
        case .soloGroom:
            executeSoloGroom(pet: pet)
        case .soloExplore:
            executeSoloExplore(pet: pet)
        default:
            break
        }
        return (type, [pet.petName])
    }

    @discardableResult
    func triggerPairInteraction(_ pet1: UUID, _ pet2: UUID) -> (type: PetInteractionType, petNames: [String])? {
        guard let c1 = controller(for: pet1),
              let c2 = controller(for: pet2),
              c1.isAvailableForInteraction,
              c2.isAvailableForInteraction else {
            return nil
        }

        let pairTypes: [PetInteractionType] = [.chase, .greet, .chat, .syncDance]
        let type = pairTypes.randomElement() ?? .greet
        executeInteraction(pet1: pet1, pet2: pet2, type: type)
        notifySpectators(excluding: [pet1, pet2])
        return (type, [c1.petName, c2.petName])
    }

    @discardableResult
    func triggerTrioInteraction(_ pet1: UUID, _ pet2: UUID, _ pet3: UUID) -> (type: PetInteractionType, petNames: [String])? {
        guard let c1 = controller(for: pet1),
              let c2 = controller(for: pet2),
              let c3 = controller(for: pet3) else {
            return nil
        }

        guard c1.isAvailableForInteraction, c2.isAvailableForInteraction, c3.isAvailableForInteraction else {
            return nil
        }

        let trioTypes: [PetInteractionType] = [.triChase, .triChat, .triPlay]
        let type = trioTypes.randomElement() ?? .triChat
        switch type {
        case .triChase:
            executeTriChase(chaser: c1, target1: c2, target2: c3)
        case .triChat:
            executeTriChat(pets: [c1, c2, c3])
        case .triPlay:
            executeTriPlay(pets: [c1, c2, c3])
        default:
            break
        }

        notifySpectators(excluding: [pet1, pet2, pet3])
        return (type, [c1.petName, c2.petName, c3.petName])
    }

    @discardableResult
    func triggerGroupInteraction(_ petIDs: [UUID]) -> (type: PetInteractionType, petNames: [String])? {
        let controllers = petIDs.compactMap(controller(for:))
        guard controllers.count >= 3,
              controllers.allSatisfy(\.isAvailableForInteraction) else {
            return nil
        }

        let groupTypes: [PetInteractionType] = [.groupCelebrate, .groupSleep, .groupFollow]
        let type = groupTypes.randomElement() ?? .groupCelebrate
        switch type {
        case .groupCelebrate:
            executeGroupCelebrate(pets: controllers)
        case .groupSleep:
            executeGroupSleep(pets: controllers)
        case .groupFollow:
            executeGroupFollow(pets: controllers)
        default:
            break
        }
        return (type, controllers.map(\.petName))
    }

    func notifySpectators(excluding participants: Set<UUID>) {
        let spectatorAnimations = ["lookAround", "react"]
        for petID in availablePets() where !participants.contains(petID) {
            guard Bool.random(), let pet = controller(for: petID) else {
                continue
            }

            let anim = spectatorAnimations.randomElement() ?? "lookAround"
            pet.playAnimationWithBubble(anim)
        }
    }

    private func randomPair(from ids: [UUID]) -> (id1: UUID, id2: UUID)? {
        guard ids.count >= 2 else {
            return nil
        }

        let shuffled = ids.shuffled()
        return (shuffled[0], shuffled[1])
    }

    private func randomTrio(from ids: [UUID]) -> (UUID, UUID, UUID)? {
        guard ids.count >= 3 else {
            return nil
        }

        let shuffled = ids.shuffled()
        return (shuffled[0], shuffled[1], shuffled[2])
    }

    private func interactionPriority(for controller: PetWindowController) -> Int {
        switch controller.animationStateSnapshotForInteraction {
        case .idle, .sit:
            return 0
        default:
            return controller.isDesktopBehaviorActive ? 2 : 1
        }
    }

    private func maybeShowActionBubble(on pet: PetWindowController, animation: String) {
        if Double.random(in: 0...1) < 0.5,
           let text = pet.actionBubbleText(for: animation) {
            pet.showBubble(text)
        }
    }

    private func executeChase(chaser: PetWindowController, target: PetWindowController) {
        let targetDelay = target.transitionPreparationDelay
        target.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay + 0.45) {
            target.debugExecuteBehavior("walk")
        }

        chaser.setTrackingTarget { [weak target] in
            target?.windowCenter
        }
        chaser.showBubble(L10n.petInteractionChaseStart)

        let chaserDelay = chaser.transitionPreparationDelay
        chaser.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + chaserDelay + 0.5) {
            chaser.debugExecuteBehavior("chase")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            target.showBubble(L10n.petInteractionChaseCaught)
        }
    }

    private func executeGreet(pet1: PetWindowController, pet2: PetWindowController) {
        pet1.transitionToState("wave")
        maybeShowActionBubble(on: pet1, animation: "wave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pet2.transitionToState("wave")
            self.maybeShowActionBubble(on: pet2, animation: "wave")
        }
    }

    private func executeChat(pet1: PetWindowController, pet2: PetWindowController) {
        let chatA = L10n.petInteractionChatA
        let chatB = L10n.petInteractionChatB
        guard !chatA.isEmpty, !chatB.isEmpty else {
            return
        }

        let rounds = min(chatA.count, chatB.count, Int.random(in: 2 ... 3))

        for i in 0..<rounds {
            let delay = Double(i) * 2.5

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pet1.transitionToState("chat")
                pet1.showBubble(chatA[i % chatA.count])
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.2) {
                pet2.transitionToState("listen")
                pet2.showBubble(chatB[i % chatB.count])
            }
        }
    }

    private func executeSyncDance(pets: [PetWindowController]) {
        for controller in pets {
            controller.transitionToState("dance")
            maybeShowActionBubble(on: controller, animation: "dance")

            let delay = controller.transitionPreparationDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) {
                controller.debugExecuteBehavior("bounce")
            }
        }
    }

    private func executeSoloPlay(pet: PetWindowController) {
        let animation = ["play", "roll", "spin"].randomElement() ?? "play"
        pet.transitionToState(animation)
        maybeShowActionBubble(on: pet, animation: animation)
    }

    private func executeSoloGroom(pet: PetWindowController) {
        pet.transitionToState("groom")
        maybeShowActionBubble(on: pet, animation: "groom")
    }

    private func executeSoloExplore(pet: PetWindowController) {
        let delay = pet.transitionPreparationDelay
        pet.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.45) {
            pet.debugExecuteBehavior("walk")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 2.0) {
            pet.transitionToState("lookAround")
            self.maybeShowActionBubble(on: pet, animation: "lookAround")
        }
    }

    private func executeTriChase(chaser: PetWindowController, target1: PetWindowController, target2: PetWindowController) {
        let target1Delay = target1.transitionPreparationDelay
        let target2Delay = target2.transitionPreparationDelay
        target1.transitionToState("walk")
        target2.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + max(target1Delay, target2Delay) + 0.45) {
            target1.debugExecuteBehavior("walk")
            target2.debugExecuteBehavior("walk")
        }

        chaser.setTrackingTarget { [weak target1] in
            target1?.windowCenter
        }
        chaser.showBubble(L10n.petInteractionChaseStart)

        let chaserDelay = chaser.transitionPreparationDelay
        chaser.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + chaserDelay + 0.4) {
            chaser.debugExecuteBehavior("chase")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            target1.showBubble("快跑！")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            target2.showBubble("别追我！")
        }
    }

    private func executeTriChat(pets: [PetWindowController]) {
        guard pets.count == 3 else { return }

        for round in 0..<3 {
            for (index, pet) in pets.enumerated() {
                let delay = Double(round * pets.count + index) * 1.1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let animation = index == round % pets.count ? "chat" : "listen"
                    pet.transitionToState(animation)
                    self.maybeShowActionBubble(on: pet, animation: animation)
                }
            }
        }
    }

    private func executeTriPlay(pets: [PetWindowController]) {
        guard pets.count == 3 else { return }

        for (index, pet) in pets.enumerated() {
            let delay = Double(index) * 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pet.transitionToState("celebrate")
                self.maybeShowActionBubble(on: pet, animation: "celebrate")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + pet.transitionPreparationDelay + 0.45) {
                pet.debugExecuteBehavior("bounce")
            }
        }
    }

    private func executeGroupCelebrate(pets: [PetWindowController]) {
        for (index, pet) in pets.enumerated() {
            let delay = Double(index) * 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pet.transitionToState("celebrate")
                self.maybeShowActionBubble(on: pet, animation: "celebrate")
            }
        }
    }

    private func executeGroupSleep(pets: [PetWindowController]) {
        for (index, pet) in pets.enumerated() {
            let delay = Double(index) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pet.transitionToState("sleep")
                self.maybeShowActionBubble(on: pet, animation: "sleep")
            }
        }
    }

    private func executeGroupFollow(pets: [PetWindowController]) {
        guard let leader = pets.first else {
            return
        }

        let leaderDelay = leader.transitionPreparationDelay
        leader.transitionToState("walk")
        DispatchQueue.main.asyncAfter(deadline: .now() + leaderDelay + 0.45) {
            leader.debugExecuteBehavior("walk")
        }

        for (index, pet) in pets.dropFirst().enumerated() {
            let delay = Double(index + 1) * 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pet.setTrackingTarget { [weak leader] in
                    leader?.windowCenter
                }
                pet.transitionToState("follow")
                self.maybeShowActionBubble(on: pet, animation: "follow")
                let prepDelay = pet.transitionPreparationDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + prepDelay) {
                    pet.debugExecuteBehavior("chase")
                }
            }
        }
    }
}
