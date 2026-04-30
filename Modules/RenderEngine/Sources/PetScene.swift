import AppKit
import Foundation
import SpriteKit

public enum HorizontalDirection: Sendable {
    case left
    case right
}

@MainActor
public final class PetScene: SKScene, @unchecked Sendable {
    public let petNode: SKSpriteNode

    private var manifest: SpriteManifest
    private let resourceBundle: Bundle
    private let animationKey = "RenderEngine.PetAnimation"
    private let effectKey = "RenderEngine.PetEffect"
    private var spritePackDirectory: URL?
    private var textureCache: [String: SKTexture] = [:]
    private var cachedPlaceholderTexture: SKTexture?

    public init(size: CGSize, manifest: SpriteManifest, resourceBundle: Bundle? = nil) {
        self.manifest = manifest
        self.resourceBundle = resourceBundle ?? Bundle.module
        self.petNode = SKSpriteNode(texture: nil, color: .clear, size: size)
        super.init(size: size)

        scaleMode = .resizeFill
        backgroundColor = .clear

        petNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(petNode)

        applyInitialTexture()
        pauseRendering()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        nil
    }

    public override func didMove(to view: SKView) {
        super.didMove(to: view)
        view.preferredFramesPerSecond = 12
    }

    public func playAnimation(for state: AnimationState) {
        guard let config = manifest.states[state.rawValue] else {
            return
        }

        let textures = loadTextures(from: config.frames)
        guard let firstTexture = textures.first else {
            return
        }

        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        resetNodeTransform()
        petNode.texture = firstTexture
        petNode.size = size  // Fill the scene, not the texture's natural size
        isPaused = false

        let animation = SKAction.animate(
            with: textures,
            timePerFrame: config.frameInterval,
            resize: false,
            restore: false
        )

        let action: SKAction
        if state == .idle {
            action = .sequence([animation, .run { [weak self] in
                self?.pauseRendering()
            }])
        } else if config.loop {
            action = .repeatForever(animation)
        } else {
            action = animation
        }

        petNode.run(action, withKey: animationKey)

        // Add visual effects for states that reuse frames
        if let effect = visualEffect(for: state) {
            petNode.run(effect, withKey: effectKey)
        }
    }

    private func visualEffect(for state: AnimationState) -> SKAction? {
        switch state {
        case .stretch:
            // Horizontal stretch: squash and stretch
            let stretchOut = SKAction.scaleX(to: 1.3, duration: 0.4)
            let stretchBack = SKAction.scaleX(to: 1.0, duration: 0.3)
            let squashY = SKAction.scaleY(to: 0.85, duration: 0.4)
            let squashBack = SKAction.scaleY(to: 1.0, duration: 0.3)
            let xAction = SKAction.sequence([stretchOut, stretchBack])
            let yAction = SKAction.sequence([squashY, squashBack])
            return SKAction.group([xAction, yAction])

        case .yawn:
            // Vertical expand (mouth opening): scale up then back
            let openUp = SKAction.scaleY(to: 1.15, duration: 0.5)
            let settle = SKAction.scaleY(to: 0.95, duration: 0.3)
            let back = SKAction.scaleY(to: 1.0, duration: 0.2)
            return SKAction.sequence([openUp, settle, back])

        case .lookAround:
            // Quick look left-right by flipping xScale
            let currentX = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
            let lookLeft = SKAction.scaleX(to: -currentX, duration: 0.15)
            let pause1 = SKAction.wait(forDuration: 0.25)
            let lookRight = SKAction.scaleX(to: currentX, duration: 0.15)
            let pause2 = SKAction.wait(forDuration: 0.25)
            return SKAction.sequence([lookLeft, pause1, lookRight, pause2, lookLeft, pause1, lookRight])

        case .bounce:
            // Squash and stretch effect (no position movement to avoid conflict with window movement)
            let squash = SKAction.group([
                SKAction.scaleX(to: 1.2, duration: 0.08),
                SKAction.scaleY(to: 0.8, duration: 0.08)
            ])
            let stretch = SKAction.group([
                SKAction.scaleX(to: 0.9, duration: 0.08),
                SKAction.scaleY(to: 1.15, duration: 0.08)
            ])
            let settle = SKAction.group([
                SKAction.scaleX(to: 1.0, duration: 0.06),
                SKAction.scaleY(to: 1.0, duration: 0.06)
            ])
            let bounce1 = SKAction.sequence([squash, stretch, settle])
            let bounce2 = SKAction.sequence([
                SKAction.group([SKAction.scaleX(to: 1.1, duration: 0.06), SKAction.scaleY(to: 0.9, duration: 0.06)]),
                SKAction.group([SKAction.scaleX(to: 1.0, duration: 0.06), SKAction.scaleY(to: 1.0, duration: 0.06)])
            ])
            return SKAction.sequence([bounce1, .wait(forDuration: 0.05), bounce2])

        case .celebrate:
            // Spin + slight scale pulse
            let pulse = SKAction.sequence([
                SKAction.scale(to: 1.1, duration: 0.15),
                SKAction.scale(to: 1.0, duration: 0.15)
            ])
            return SKAction.repeat(pulse, count: 2)

        case .react:
            // Quick scale wobble (no position movement to avoid conflict with window movement)
            let wobble = SKAction.sequence([
                SKAction.scaleX(to: 0.9, duration: 0.04),
                SKAction.scaleX(to: 1.1, duration: 0.04),
                SKAction.scaleX(to: 1.0, duration: 0.04)
            ])
            return SKAction.repeat(wobble, count: 2)

        case .spin:
            return SKAction.rotate(byAngle: .pi * 2, duration: 0.5)

        case .love:
            let pulse = SKAction.sequence([
                SKAction.scale(to: 1.15, duration: 0.2),
                SKAction.scale(to: 1.0, duration: 0.2)
            ])
            return SKAction.repeat(pulse, count: 2)

        case .scared:
            let shake = SKAction.sequence([
                SKAction.scaleX(to: 0.95, duration: 0.03),
                SKAction.scaleX(to: 1.05, duration: 0.03),
                SKAction.scaleX(to: 1.0, duration: 0.03)
            ])
            return SKAction.repeat(shake, count: 4)

        case .dance:
            let currentX = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
            let sway = SKAction.sequence([
                SKAction.scaleX(to: -currentX, duration: 0.2),
                SKAction.scaleX(to: currentX, duration: 0.2)
            ])
            return SKAction.repeat(sway, count: 2)

        default:
            return nil
        }
    }

    private func resetNodeTransform() {
        let currentXDirection: CGFloat = petNode.xScale < 0 ? -1 : 1
        petNode.xScale = currentXDirection
        petNode.yScale = 1
        petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// 翻跟头各阶段时长（秒），方便 PetWindowController 同步窗口平移。
    public static let somersaultPrepDuration: TimeInterval = 0.18 + 0.35
    public static let somersaultPerFlipDuration: TimeInterval = 0.55
    public static let somersaultSettleDuration: TimeInterval = 0.08 + 0.14
    /// 落地后到招手收势之间的停顿。
    public static let somersaultPrePunchPause: TimeInterval = 0.22
    /// 单段收势时长：招手摆动的「外摆 → 回摆 → 回正」，与 `somersaultPerJabDuration` 一致。
    public static let somersaultJabCount: Int = 3
    public static let somersaultPerJabDuration: TimeInterval = 0.12 + 0.11 + 0.12 + 0.17  // 0.52s
    public static let somersaultPunchComboDuration: TimeInterval =
        somersaultPrePunchPause
        + Double(somersaultJabCount) * somersaultPerJabDuration
        + 0.15

    public static func somersaultTotalDuration(count: Int) -> TimeInterval {
        let flips = max(1, min(count, 8))
        return somersaultPrepDuration
            + Double(flips) * somersaultPerFlipDuration
            + somersaultSettleDuration
            + somersaultPunchComboDuration
    }

    /// 招手式摆动：外展 → 反向轻带 → 回中立，总时长等于 `somersaultPerJabDuration`。
    private func somersaultWaveLikeGesture(bx: CGFloat, side: CGFloat, duration: TimeInterval) -> SKAction {
        let t1 = duration * 0.30
        let t2 = duration * 0.35
        let t3 = duration * 0.35
        let swayOut = SKAction.group([
            SKAction.rotate(toAngle: side * .pi / 10, duration: t1, shortestUnitArc: true),
            SKAction.scaleX(to: bx * 1.05, duration: t1),
            SKAction.scaleY(to: 1.05, duration: t1)
        ])
        swayOut.timingMode = .easeOut
        let swayBack = SKAction.group([
            SKAction.rotate(toAngle: -side * .pi / 12, duration: t2, shortestUnitArc: true),
            SKAction.scaleX(to: bx * 0.97, duration: t2),
            SKAction.scaleY(to: 0.99, duration: t2)
        ])
        swayBack.timingMode = .easeInEaseOut
        let settle = SKAction.group([
            SKAction.rotate(toAngle: 0, duration: t3, shortestUnitArc: true),
            SKAction.scaleX(to: bx, duration: t3),
            SKAction.scaleY(to: 1.0, duration: t3)
        ])
        settle.timingMode = .easeOut
        return SKAction.sequence([swayOut, swayBack, settle])
    }

    /// 翻跟头：准备与空翻同上，落地后用与 `wave` 相同的精灵姿 + 招手式侧摆收势（非冲拳）。
    /// 平移由 PetWindowController 用 `somersault*Duration` 常量驱动 NSWindow，造成「在屏幕上翻滚」的效果。
    public func playSomersault(count: Int) {
        let flips = max(1, min(count, 8))

        // 严肃皱眉表情：优先用 manifest 里的 somersault 帧（适配自定义 sprite pack），
        // 退回到 angry → idle，最后兜底硬编码 pet_angry_0（默认 cat 包）。
        let candidateNames: [String] = [
            manifest.states[AnimationState.somersault.rawValue]?.frames.first,
            manifest.states[AnimationState.angry.rawValue]?.frames.first,
            manifest.states[AnimationState.idle.rawValue]?.frames.first,
            "pet_angry_0"
        ].compactMap { $0 }

        let seriousTexture: SKTexture
        if let real = candidateNames.lazy.compactMap({ self.loadRealTexture(named: $0) }).first {
            seriousTexture = real
        } else {
            return
        }

        let waveTexture: SKTexture? = {
            guard let name = manifest.states[AnimationState.wave.rawValue]?.frames.first else { return nil }
            return loadRealTexture(named: name)
        }()

        petNode.removeAction(forKey: animationKey)
        petNode.removeAction(forKey: effectKey)
        resetNodeTransform()

        petNode.texture = seriousTexture
        petNode.size = size
        isPaused = false

        let facingSign: CGFloat = petNode.xScale < 0 ? -1 : 1
        let facingScale = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
        let flipDirection: CGFloat = facingSign >= 0 ? -1 : 1  // 朝向决定翻滚方向

        // 准备：蓄力后倾 —— 略扁、拉高、角度稍大，再短暂屏息
        let rearUp = SKAction.group([
            SKAction.scaleX(to: facingSign * facingScale * 0.82, duration: 0.18),
            SKAction.scaleY(to: 1.22, duration: 0.18),
            SKAction.rotate(toAngle: flipDirection * .pi / 9, duration: 0.18, shortestUnitArc: true)
        ])
        rearUp.timingMode = .easeOut
        let braceHold = SKAction.wait(forDuration: 0.35)

        let bx = facingSign * facingScale
        let flipDur = Self.somersaultPerFlipDuration
        let quarter = flipDur * 0.25
        // 翻滚：旋转带缓动 + 四拍挤压拉伸，避免「纸片匀速转」的廉价感
        let tuckCycle = SKAction.sequence([
            SKAction.group([
                SKAction.scaleY(to: 0.84, duration: quarter),
                SKAction.scaleX(to: bx * 1.16, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 1.16, duration: quarter),
                SKAction.scaleX(to: bx * 0.88, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 0.88, duration: quarter),
                SKAction.scaleX(to: bx * 1.12, duration: quarter)
            ]),
            SKAction.group([
                SKAction.scaleY(to: 1.0, duration: quarter),
                SKAction.scaleX(to: bx, duration: quarter)
            ])
        ])
        let rotOnce = SKAction.rotate(byAngle: flipDirection * .pi * 2, duration: flipDur)
        rotOnce.timingMode = .easeInEaseOut
        let flipOnce = SKAction.group([rotOnce, tuckCycle])
        let flipSequence = SKAction.repeat(flipOnce, count: flips)

        // 落地：轻微着地挤压再弹回（仍保持面向 bx）
        let landSquash = SKAction.group([
            SKAction.scaleX(to: bx * 1.08, duration: 0.08),
            SKAction.scaleY(to: 0.88, duration: 0.08),
            SKAction.rotate(toAngle: 0, duration: 0.08, shortestUnitArc: true)
        ])
        landSquash.timingMode = .easeIn
        let settle = SKAction.group([
            SKAction.scaleX(to: bx, duration: 0.14),
            SKAction.scaleY(to: 1.0, duration: 0.14)
        ])
        settle.timingMode = .easeOut
        let landing = SKAction.sequence([landSquash, settle])

        let adoptWaveTexture = SKAction.run { [weak self] in
            guard let self, let waveTexture else { return }
            self.petNode.texture = waveTexture
        }
        let restoreSeriousTexture = SKAction.run { [weak self] in
            guard let self else { return }
            self.petNode.texture = seriousTexture
        }

        // 收势：`wave` 精灵 + 左右交替的招手摆动（与单段时长常量一致）
        var waveSegments: [SKAction] = []
        for i in 0..<Self.somersaultJabCount {
            let side: CGFloat = (i % 2 == 0) ? 1 : -1
            waveSegments.append(somersaultWaveLikeGesture(bx: bx, side: side, duration: Self.somersaultPerJabDuration))
        }
        let punchCombo = SKAction.sequence(
            [SKAction.wait(forDuration: Self.somersaultPrePunchPause)]
                + [adoptWaveTexture]
                + waveSegments
                + [SKAction.wait(forDuration: 0.15), restoreSeriousTexture]
        )

        let full = SKAction.sequence([rearUp, braceHold, flipSequence, landing, punchCombo])
        petNode.run(full, withKey: animationKey)
    }

    public func setFacing(_ direction: HorizontalDirection) {
        let currentScale = abs(petNode.xScale == 0 ? 1 : petNode.xScale)
        petNode.xScale = direction == .left ? -currentScale : currentScale
    }

    public func setRotation(_ angle: CGFloat) {
        petNode.zRotation = angle
    }

    public func pauseRendering() {
        isPaused = true
    }

    public func resumeRendering() {
        isPaused = false
    }

    /// 从当前 manifest 加载语言包文字
    public func loadLanguageTexts(key: String) -> [String]? {
        manifest.language?[key]
    }

    public func loadSpritePack(from directory: URL?) {
        if let directory,
           let manifest = try? SpritePackLoader.loadManifest(from: directory) {
            self.manifest = manifest
            self.spritePackDirectory = directory
        } else {
            manifest = SpritePackLoader.loadBundledManifest()
            spritePackDirectory = nil
        }

        textureCache.removeAll()
        cachedPlaceholderTexture = nil
        petNode.removeAction(forKey: animationKey)
        applyInitialTexture()
    }

    private func applyInitialTexture() {
        let initialFrames = manifest.states[AnimationState.idle.rawValue]?.frames
            ?? manifest.states.values.first?.frames
            ?? []

        guard let firstFrame = initialFrames.first,
              let texture = loadTexture(named: firstFrame) else {
            return
        }

        petNode.texture = texture
        petNode.size = size  // Fill the scene
    }

    private func loadTextures(from frameNames: [String]) -> [SKTexture] {
        frameNames.compactMap { loadTexture(named: $0) }
    }

    private func loadTexture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] {
            return cached
        }
        if let texture = loadRealTexture(named: name) {
            return texture
        }
        return placeholderTexture()
    }

    /// 只在真正能加载到资源时返回纹理，找不到返回 nil（不退回 placeholder），用于按 manifest 顺序级联回退。
    private func loadRealTexture(named name: String) -> SKTexture? {
        if let cached = textureCache[name] {
            return cached === cachedPlaceholderTexture ? nil : cached
        }

        if let spritePackDirectory {
            let textureURL = spritePackDirectory.appendingPathComponent("\(name).png")
            if let image = NSImage(contentsOf: textureURL) {
                let texture = SKTexture(image: image)
                texture.filteringMode = .nearest
                textureCache[name] = texture
                return texture
            }
            return nil
        }

        if let url = resourceBundle.url(forResource: name, withExtension: "png", subdirectory: "Resources") ??
                      resourceBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let texture = SKTexture(image: image)
            texture.filteringMode = .nearest
            textureCache[name] = texture
            return texture
        }

        return nil
    }

    private func placeholderTexture() -> SKTexture {
        if let cached = cachedPlaceholderTexture {
            return cached
        }

        let imageSize = CGSize(width: 32, height: 32)
        let image = NSImage(size: imageSize)
        image.lockFocus()

        NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()

        NSColor.white.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 3
        cross.move(to: CGPoint(x: 6, y: 6))
        cross.line(to: CGPoint(x: 26, y: 26))
        cross.move(to: CGPoint(x: 26, y: 6))
        cross.line(to: CGPoint(x: 6, y: 26))
        cross.stroke()

        image.unlockFocus()

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        cachedPlaceholderTexture = texture
        return texture
    }
}
