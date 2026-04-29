import Foundation
import Security

public enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case unhandledError(OSStatus)
}

public actor KeychainManager {
    private let service: String

    public init(service: String = "app.vitapet.secrets") {
        self.service = service
    }

    public func set(_ value: Data, forKey key: String) async throws {
        let query = baseQuery(forKey: key)

        let status = SecItemAdd(query.merging([kSecValueData: value]) { $1 } as CFDictionary, nil)

        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let update = [kSecValueData: value] as CFDictionary
            let updateStatus = SecItemUpdate(query as CFDictionary, update)
            if updateStatus != errSecSuccess {
                throw KeychainError.unhandledError(updateStatus)
            }
            return
        }

        throw KeychainError.unhandledError(status)
    }

    public func get(forKey key: String) async throws -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status)
        }

        return result as? Data
    }

    public func delete(forKey key: String) async throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw KeychainError.unhandledError(status)
    }

    public func setString(_ value: String, forKey key: String) async throws {
        try await set(Data(value.utf8), forKey: key)
    }

    public func getString(forKey key: String) async throws -> String? {
        guard let data = try await get(forKey: key) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func baseQuery(forKey key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}
