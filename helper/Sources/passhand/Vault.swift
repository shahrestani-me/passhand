import Foundation
import Security
import LocalAuthentication

/// The "box": generic-password items in your login Keychain.
/// service = "passhand:<origin>", account = username.
/// Items are created by this binary, so macOS only lets this binary read them without asking you.
enum Vault {
    static let prefix = "passhand:"
    static let marker = "passhand login"
    // Per-login fill policy, stored on the Keychain item itself (kSecAttrComment).
    static let autoMark = "fill:auto"
    static let promptMark = "fill:touchid"

    struct Entry { let origin: String; let username: String; let auto: Bool }

    static func service(_ origin: String) -> String { prefix + origin }

    static func save(origin: String, username: String, password: String, auto: Bool) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(origin),
            kSecAttrAccount as String: username,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Passhand: \(origin)"
        item[kSecAttrDescription as String] = marker
        item[kSecAttrComment as String] = auto ? autoMark : promptMark
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    static func setAuto(origin: String, username: String, auto: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(origin),
            kSecAttrAccount as String: username,
        ]
        let changes: [String: Any] = [kSecAttrComment as String: auto ? autoMark : promptMark]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    static func list() -> [Entry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrDescription as String: marker,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { a -> Entry? in
            guard let s = a[kSecAttrService as String] as? String, s.hasPrefix(prefix),
                  let user = a[kSecAttrAccount as String] as? String else { return nil }
            let auto = (a[kSecAttrComment as String] as? String) == autoMark
            return Entry(origin: String(s.dropFirst(prefix.count)), username: user, auto: auto)
        }
        .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }

    static func entries(origin: String) -> [Entry] {
        list().filter { $0.origin == origin }
    }

    static func password(origin: String, username: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(origin),
            kSecAttrAccount as String: username,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { throw VaultError.keychain(status) }
        return value
    }

    @discardableResult
    static func remove(origin: String, username: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(origin),
            kSecAttrAccount as String: username,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// Touch ID (or your Mac password) before every password fill.
enum Auth {
    static func confirm(_ reason: String, timeout: TimeInterval = 90) throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw VaultError.message("Touch ID / password check is unavailable: \(error?.localizedDescription ?? "unknown reason")")
        }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            ok = success
            done.signal()
        }
        // Don't let an unanswered prompt fill something minutes later.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { context.invalidate() }
        done.wait()
        if !ok { throw VaultError.authFailed }
    }
}
