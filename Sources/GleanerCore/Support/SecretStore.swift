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

/// Stores secrets in a JSON file readable only by the user (mode 0600, in a 0700 folder).
///
/// Used instead of the keychain because Gleaner is signed with a self-signed certificate: with no
/// team identifier, the keychain recognizes the app by the exact build, so every update would ask
/// for the login password again. The file is as private as other per-user credentials (such as
/// `~/.aws/credentials`): readable by programs running as the user, not by other users.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func secret(for account: String) -> String {
        lock.withLock { load()[account] ?? "" }
    }

    public func setSecret(_ value: String, for account: String) {
        lock.withLock {
            var secrets = load()
            secrets[account] = value.isEmpty ? nil : value
            save(secrets)
        }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return secrets
    }

    private func save(_ secrets: [String: String]) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        // Created with owner-only permissions before any secret is written into it.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Reads and writes `primary`, moving each secret over from `legacy` the first time it's asked for.
public struct MigratingSecretStore: SecretStore {
    public let primary: SecretStore
    public let legacy: SecretStore

    public init(primary: SecretStore, legacy: SecretStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func secret(for account: String) -> String {
        let current = primary.secret(for: account)
        if !current.isEmpty { return current }
        let old = legacy.secret(for: account)
        if !old.isEmpty {
            primary.setSecret(old, for: account)
            legacy.setSecret("", for: account)
        }
        return old
    }

    public func setSecret(_ value: String, for account: String) {
        primary.setSecret(value, for: account)
        legacy.setSecret("", for: account)
    }
}
