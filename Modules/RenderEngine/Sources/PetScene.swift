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

        if let spritePackDirectory {
            let textureURL = spritePackDirectory.appendingPathComponent("\(name).png")
            if let image = NSImage(contentsOf: textureURL) {
                let texture = SKTexture(image: image)
                texture.filteringMode = .nearest
                textureCache[name] = texture
                return texture
            }

            return placeholderTexture()
        }

        // Try loading from bundle resources (SPM Bundle.module)
        if let url = resourceBundle.url(forResource: name, withExtension: "png", subdirectory: "Resources") ??
                      resourceBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let texture = SKTexture(image: image)
            texture.filteringMode = .nearest
            textureCache[name] = texture
            return texture
        }

        return placeholderTexture()
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
