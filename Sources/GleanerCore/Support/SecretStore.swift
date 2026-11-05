import Foundation
import Security

/// Storage for API keys.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String
    /// Stores `value`; an empty value deletes the secret.
    func setSecret(_ value: String, for account: String)
}

/// Stores secrets as generic passwords in the user's login keychain.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "app.gleaner.Gleaner.api-key") {
        self.service = service
    }

    public func secret(for account: String) -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func setSecret(_ value: String, for account: String) {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
