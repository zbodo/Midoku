import Foundation
import Security

// Aidoku sources read their login fields through UserDefaults. Keep passwords
// in Keychain and expose them through a volatile domain, without writing them
// into the preferences plist or the library JSON.
@MainActor
enum SourceCredentials {
    private static let service = "app.midoku.source-logins"
    private struct Login: Codable {
        let username: String
        let password: String
    }
    private static func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
    private static func registry(_ sourceKey: String) -> String { "midoku.login-accounts." + sourceKey }

    static func save(sourceKey: String, key: String, username: String, password: String) throws {
        let login = Login(username: username, password: password)
        let data = try JSONEncoder().encode(login)
        let status = SecItemUpdate(query(account: key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: key)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
        var accounts = UserDefaults.standard.stringArray(forKey: registry(sourceKey)) ?? []
        if !accounts.contains(key) { accounts.append(key) }
        UserDefaults.standard.set(accounts, forKey: registry(sourceKey))
        mirror(login, key: key)
    }
    static func restore(sourceKey: String) throws {
        // Public sources never need a Keychain query or an authentication prompt.
        for key in UserDefaults.standard.stringArray(forKey: registry(sourceKey)) ?? [] {
            var request = query(account: key)
            request[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            try check(status)
            guard let data = result as? Data else { continue }
            mirror(try JSONDecoder().decode(Login.self, from: data), key: key)
        }
    }
    static func remove(sourceKey: String, key: String) throws {
        let status = SecItemDelete(query(account: key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        let accounts = (UserDefaults.standard.stringArray(forKey: registry(sourceKey)) ?? []).filter { $0 != key }
        UserDefaults.standard.set(accounts, forKey: registry(sourceKey))
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain.removeValue(forKey: key + ".username")
        domain.removeValue(forKey: key + ".password")
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
    private static func mirror(_ login: Login, key: String) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key + ".username"] = login.username
        domain[key + ".password"] = login.password
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error."
                ])
        }
    }
}
