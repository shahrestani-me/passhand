import Foundation

/// Requests from the extension's settings page (forwarded by its background worker, the only code that
/// holds the Chrome connection). Every change asks for Touch ID / Windows Hello, except turning auto off,
/// which only makes fills stricter. Nothing returned from here contains a password.
enum Settings {
    private static let lock = NSLock()

    static func handle(_ request: [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        do {
            var reply = try run(request)
            reply["ok"] = true
            return reply
        } catch VaultError.authFailed {
            return ["ok": false, "error": "\(Auth.name) was not confirmed, so nothing was changed."]
        } catch {
            Log.write("settings request failed: \(error)")
            return ["ok": false, "error": "\(error)"]
        }
    }

    private static func run(_ r: [String: Any]) throws -> [String: Any] {
        switch r["cmd"] as? String {
        case "logins.list":
            return ["logins": Vault.list().map { ["origin": $0.origin, "username": $0.username, "auto": $0.auto] }]

        case "logins.save":
            let site = r["site"] as? String ?? ""
            guard let origin = Origin.forSaving(site) else {
                throw VaultError.message("\(site.isEmpty ? "The site" : site) isn't accepted: enter the site's full address, like https://example.com. Only https sites (and localhost / *.test for development) can be saved.")
            }
            let user = try username(r)
            guard let password = r["password"] as? String, !password.isEmpty else {
                throw VaultError.message("Enter a password.")
            }
            let auto = r["auto"] as? Bool ?? false
            let replaced = Vault.entries(origin: origin).contains { $0.username == user }
            try Auth.confirm(auto ? "let AI agents fill \(user) on \(origin) without asking"
                             : replaced ? "replace the password for \(user) on \(origin)"
                             : "save a login for \(user) on \(origin)")
            try Vault.save(origin: origin, username: user, password: password, auto: auto)
            Log.write("settings page saved \(user) on \(origin)\(auto ? " (auto)" : "")")
            return ["origin": origin, "username": user, "auto": auto, "replaced": replaced]

        case "logins.remove":
            let (origin, user) = try existing(r)
            try Auth.confirm("remove the login for \(user) on \(origin)")
            Vault.remove(origin: origin, username: user)
            Log.write("settings page removed \(user) on \(origin)")
            return ["origin": origin, "username": user]

        case "logins.auto":
            let (origin, user) = try existing(r)
            let on = r["auto"] as? Bool ?? false
            if on { try Auth.confirm("let AI agents fill \(user) on \(origin) without asking") }
            try Vault.setAuto(origin: origin, username: user, auto: on)
            Log.write("settings page set \(user) on \(origin) to \(on ? "auto" : Auth.name.lowercased())")
            return ["origin": origin, "username": user, "auto": on]

        default:
            throw VaultError.message("Unknown settings request.")
        }
    }

    private static func username(_ r: [String: Any]) throws -> String {
        let user = (r["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw VaultError.message("Enter a username.") }
        return user
    }

    /// A login that is already saved. The origin must already be in normalized form, as the list returns it.
    private static func existing(_ r: [String: Any]) throws -> (String, String) {
        let user = try username(r)
        guard let origin = Origin.normalize(r["origin"] as? String ?? ""),
              Vault.entries(origin: origin).contains(where: { $0.username == user })
        else { throw VaultError.message("That login isn't saved any more. Reload the page.") }
        return (origin, user)
    }
}
