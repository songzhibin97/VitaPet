import Foundation

public struct ExemptionList: Sendable {
    /// 这些 App 全屏时不触发 Focus 模式
    public var exemptedBundleIds: Set<String>

    public init(exemptedBundleIds: Set<String> = []) {
        self.exemptedBundleIds = exemptedBundleIds
    }

    public func isExempted(bundleId: String) -> Bool {
        exemptedBundleIds.contains(bundleId)
    }

    public mutating func add(bundleId: String) {
        exemptedBundleIds.insert(bundleId)
    }

    public mutating func remove(bundleId: String) {
        exemptedBundleIds.remove(bundleId)
    }
}
