public enum AnimationTrigger: Sendable {
    case timer
    case appSwitch
    case userInteract
    case focusEnter
    case focusExit
    case custom(String)
}
