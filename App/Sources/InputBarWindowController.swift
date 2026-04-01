import AppKit
import Localization

@MainActor
final class InputBarWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onSubmitWithTargets: ((String, Set<UUID>) -> Void)?
    var onSubmitToConversation: ((String, String) -> Void)?  // text, conversationId

    private var availablePets: [(id: UUID, name: String)] = []
    private var selectedPetIDs: Set<UUID> = []
    private var chipButtons: [UUID: NSButton] = [:]

    // Conversation-based selection
    private var availableConversations: [(id: String, title: String, type: String)] = []
    private var selectedConversationId: String?
    private var conversationChipButtons: [String: NSButton] = [:]

    private let inputField = NSTextField()
    private let chipContainer = NSView()
    private var chipScrollView: NSScrollView?

    init() {
        let window = InputBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 88),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        shouldCascadeWindows = false
        window.level = .floating + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.delegate = self

        let contentView = NSVisualEffectView()
        contentView.frame = NSRect(x: 0, y: 0, width: 500, height: 88)
        contentView.autoresizingMask = [.width, .height]
        contentView.blendingMode = .behindWindow
        contentView.material = .hudWindow
        contentView.state = .active
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.isBordered = false
        inputField.isBezeled = false
        inputField.backgroundColor = .clear
        inputField.drawsBackground = false
        inputField.textColor = .white
        inputField.font = .systemFont(ofSize: 18)
        inputField.alignment = .left
        inputField.placeholderString = "问点什么..."
        inputField.delegate = self
        inputField.focusRingType = .none
        inputField.target = self
        inputField.action = #selector(submit)
        inputField.refusesFirstResponder = false
        inputField.appearance = NSAppearance(named: .darkAqua)

        chipContainer.translatesAutoresizingMaskIntoConstraints = false

        let chipScrollView = NSScrollView()
        chipScrollView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.hasHorizontalScroller = false
        chipScrollView.hasVerticalScroller = false
        chipScrollView.drawsBackground = false
        chipScrollView.documentView = chipContainer
        chipScrollView.isHidden = true
        self.chipScrollView = chipScrollView

        contentView.addSubview(chipScrollView)
        contentView.addSubview(inputField)
        NSLayoutConstraint.activate([
            chipScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            chipScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chipScrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            chipScrollView.heightAnchor.constraint(equalToConstant: 28),
            inputField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            inputField.heightAnchor.constraint(equalToConstant: 28),
            inputField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        window.contentView = contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configureAvailablePets(_ pets: [(id: UUID, name: String)]) {
        availablePets = pets
        selectedPetIDs = Set(pets.map(\.id))
    }

    func preselectPets(_ petIds: Set<UUID>) {
        selectedPetIDs = petIds.isEmpty ? Set(availablePets.map(\.id)) : petIds
    }

    func configureConversations(_ conversations: [(id: String, title: String, type: String)], selectedId: String?) {
        availableConversations = conversations
        selectedConversationId = selectedId ?? conversations.first?.id
    }

    func show() {
        guard let window else {
            return
        }

        inputField.stringValue = ""
        rebuildChips()
        updatePlaceholder()

        let hasChips = !availableConversations.isEmpty || availablePets.count > 1
        let windowHeight: CGFloat = hasChips ? 88 : 48
        let screenFrame = NSScreen.main?.frame ?? window.frame
        let newOrigin = CGPoint(
            x: screenFrame.midX - 250,
            y: screenFrame.minY + (screenFrame.height * 0.7)
        )
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: 500, height: windowHeight))
        window.setFrame(newFrame, display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputField)
    }

    func windowDidResignKey(_ notification: Notification) {
        closeInputBar()
    }

    @objc private func submit() {
        let trimmedText = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            closeInputBar()
            return
        }

        if let onSubmitToConversation, let convId = selectedConversationId, !availableConversations.isEmpty {
            onSubmitToConversation(trimmedText, convId)
        } else if let onSubmitWithTargets {
            onSubmitWithTargets(trimmedText, selectedPetIDs)
        } else {
            onSubmit?(trimmedText)
        }
        closeInputBar()
    }

    private func rebuildChips() {
        chipContainer.subviews.forEach { $0.removeFromSuperview() }
        chipButtons.removeAll()
        conversationChipButtons.removeAll()

        // If we have conversations, show conversation chips
        if !availableConversations.isEmpty {
            chipScrollView?.isHidden = false
            window?.setContentSize(NSSize(width: 500, height: 88))

            var xOffset: CGFloat = 0
            for (index, conv) in availableConversations.enumerated() {
                let isSelected = conv.id == selectedConversationId
                let icon = conv.type == "group" ? "👥" : "🐱"
                let button = NSButton()
                button.title = isSelected ? "\(icon) \(conv.title) ✓" : "\(icon) \(conv.title)"
                button.bezelStyle = .roundRect
                button.setButtonType(.onOff)
                button.state = isSelected ? .on : .off
                button.target = self
                button.action = #selector(conversationChipTapped(_:))
                button.tag = index
                button.font = .systemFont(ofSize: 12)
                button.appearance = NSAppearance(named: .darkAqua)
                button.sizeToFit()
                button.frame.origin = CGPoint(x: xOffset, y: 0)

                chipContainer.addSubview(button)
                conversationChipButtons[conv.id] = button
                xOffset += button.frame.width + 6
            }
            chipContainer.frame = NSRect(x: 0, y: 0, width: xOffset, height: 28)
            return
        }

        // Fallback: pet chips (for backward compatibility)
        guard availablePets.count > 1 else {
            chipScrollView?.isHidden = true
            window?.setContentSize(NSSize(width: 500, height: 48))
            return
        }

        chipScrollView?.isHidden = false
        window?.setContentSize(NSSize(width: 500, height: 88))

        var xOffset: CGFloat = 0
        for (index, pet) in availablePets.enumerated() {
            let isSelected = selectedPetIDs.contains(pet.id)
            let button = NSButton()
            button.title = isSelected ? "✓ \(pet.name)" : "  \(pet.name)"
            button.bezelStyle = .roundRect
            button.setButtonType(.toggle)
            button.state = isSelected ? .on : .off
            button.target = self
            button.action = #selector(chipTapped(_:))
            button.tag = index
            button.font = .systemFont(ofSize: 12)
            button.appearance = NSAppearance(named: .darkAqua)
            button.sizeToFit()
            button.frame.origin = CGPoint(x: xOffset, y: 0)

            chipContainer.addSubview(button)
            chipButtons[pet.id] = button
            xOffset += button.frame.width + 6
        }
        chipContainer.frame = NSRect(x: 0, y: 0, width: xOffset, height: 28)
    }

    @objc private func conversationChipTapped(_ sender: NSButton) {
        guard sender.tag < availableConversations.count else { return }
        let conv = availableConversations[sender.tag]
        selectedConversationId = conv.id

        for (id, button) in conversationChipButtons {
            let isSelected = id == selectedConversationId
            let c = availableConversations.first(where: { $0.id == id })
            let icon = c?.type == "group" ? "👥" : "🐱"
            button.title = isSelected ? "\(icon) \(c?.title ?? "") ✓" : "\(icon) \(c?.title ?? "")"
            button.state = isSelected ? .on : .off
        }

        updatePlaceholder()
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard sender.tag < availablePets.count else {
            return
        }

        let pet = availablePets[sender.tag]
        if selectedPetIDs.contains(pet.id) {
            if selectedPetIDs.count > 1 {
                selectedPetIDs.remove(pet.id)
            }
        } else {
            selectedPetIDs.insert(pet.id)
        }

        for pet in availablePets {
            let isSelected = selectedPetIDs.contains(pet.id)
            chipButtons[pet.id]?.title = isSelected ? "✓ \(pet.name)" : "  \(pet.name)"
            chipButtons[pet.id]?.state = isSelected ? .on : .off
        }

        updatePlaceholder()
    }

    private func updatePlaceholder() {
        // Conversation-based placeholder
        if !availableConversations.isEmpty {
            if let convId = selectedConversationId,
               let conv = availableConversations.first(where: { $0.id == convId }) {
                inputField.placeholderString = String(format: L10n.chatPlaceholderSelectedPets, conv.title)
            } else {
                inputField.placeholderString = L10n.chatPlaceholderAllPets
            }
            return
        }

        // Legacy pet-based placeholder
        if selectedPetIDs.count == availablePets.count || availablePets.count <= 1 {
            inputField.placeholderString = L10n.chatPlaceholderAllPets
        } else {
            let names = availablePets
                .filter { selectedPetIDs.contains($0.id) }
                .map(\.name)
                .joined(separator: "、")
            inputField.placeholderString = String(format: L10n.chatPlaceholderSelectedPets, names)
        }
    }

    private func closeInputBar() {
        guard let window else {
            return
        }

        window.orderOut(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            submit()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeInputBar()
            return true
        }

        return false
    }
}

@MainActor
private final class InputBarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
