import Foundation
#if os(Windows)
import WinSDK
#endif

// Native messaging host: Chrome starts this process when the extension connects and keeps it
// alive while the connection is open. It is the only process that ever reads a password.
//
//   MCP process ──(local socket, no secrets)──► this host ──(stdio, Chrome)──► extension ──► page

enum NativeHost {
    static func run() -> Never {
        #if os(Windows)
        // Chrome on Windows also passes the window that started us, for the Windows Hello prompt.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--parent-window=") }),
           let handle = Int(arg.dropFirst("--parent-window=".count)), handle != 0 {
            Auth.parentWindow = HWND(bitPattern: handle)
        }
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
        Paths.ensure()
        Log.write("host started")
        SocketServer.start()
        while let message = Framing.read() {
            // "req" marks a request the extension starts (its settings page); everything else answers ours.
            // Settings requests can wait on Touch ID / Windows Hello, so they run off the read loop.
            if let req = message["req"] as? String {
                Thread.detachNewThread {
                    var reply = Settings.handle(message)
                    reply["req"] = req
                    Framing.write(reply)
                }
            } else {
                ExtensionLink.shared.deliver(message)
            }
        }
        Log.write("Chrome closed the connection; host exiting")
        LocalSocket.cleanUp()
        exit(0)
    }
}

/// Chrome's native messaging format: 4-byte length (native byte order) + UTF-8 JSON.
enum Framing {
    private static let writeLock = NSLock()

    private static func readExact(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { StdStream.read($0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return Data(buffer)
    }

    static func read() -> [String: Any]? {
        guard let header = readExact(4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length < 64 * 1024 * 1024, let body = readExact(Int(length)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func write(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(body.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        writeLock.lock()
        defer { writeLock.unlock() }
        frame.withUnsafeBytes { StdStream.write($0) }
    }
}

/// Request/response over the Chrome connection, matched by id.
final class ExtensionLink {
    static let shared = ExtensionLink()

    private final class Pending {
        let done = DispatchSemaphore(value: 0)
        var reply: [String: Any]?
    }

    private let lock = NSLock()
    private var waiting: [String: Pending] = [:]

    func call(_ message: [String: Any], timeout: TimeInterval = 20) throws -> [String: Any] {
        let id = UUID().uuidString
        let pending = Pending()
        lock.lock(); waiting[id] = pending; lock.unlock()
        var outgoing = message
        outgoing["id"] = id
        Framing.write(outgoing)
        let result = pending.done.wait(timeout: .now() + timeout)
        lock.lock(); waiting[id] = nil; lock.unlock()
        guard result == .success, let reply = pending.reply else {
            throw VaultError.message("The Chrome extension did not answer in time.")
        }
        if let ok = reply["ok"] as? Bool, !ok {
            throw VaultError.message(reply["error"] as? String ?? "The Chrome extension reported an error.")
        }
        return reply
    }

    func deliver(_ message: [String: Any]) {
        guard let id = message["id"] as? String else { return }
        lock.lock(); let pending = waiting[id]; lock.unlock()
        pending?.reply = message
        pending?.done.signal()
    }
}

/// The local socket the MCP process connects to (see LocalSocket.swift for who may connect).
enum SocketServer {
    private static let fillLock = NSLock()

    static func start() {
        LocalSocket.listen(handle)
    }

    private static func handle(_ connection: LocalConnection) {
        guard let line = connection.readLine(),
              let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }

        var response: [String: Any]
        switch request["op"] as? String {
        case "ping":
            let extensionAlive = (try? ExtensionLink.shared.call(["cmd": "ping"], timeout: 5)) != nil
            response = ["ok": true, "extension": extensionAlive]
        case "fill_login":
            fillLock.lock()
            do {
                response = try Filler.fillLogin(
                    pageURL: request["page_url"] as? String ?? "",
                    username: request["username"] as? String,
                    submit: request["submit"] as? Bool ?? false,
                    tabId: request["tab_id"] as? Int)
                response["ok"] = true
            } catch {
                Log.write("fill failed: \(error)")
                response = ["ok": false, "error": "\(error)"]
            }
            fillLock.unlock()
        default:
            response = ["ok": false, "error": "Unknown request"]
        }

        if var data = try? JSONSerialization.data(withJSONObject: response) {
            data.append(0x0A)
            connection.write(data)
        }
    }
}

/// The actual decision logic. Nothing returned from here contains a password.
enum Filler {
    static func fillLogin(pageURL: String, username: String?, submit: Bool, tabId: Int? = nil) throws -> [String: Any] {
        guard !pageURL.isEmpty else { throw VaultError.message("page_url is required.") }

        // 1. Ask the extension which tab this is and what inputs are on it.
        //    The origin comes from Chrome's own record of the tab, never from the agent or the page text.
        var inspectRequest: [String: Any] = ["cmd": "inspect", "page_url": pageURL]
        if let tabId { inspectRequest["tab_id"] = tabId }
        let inspection = try ExtensionLink.shared.call(inspectRequest)
        guard let tabId = inspection["tab_id"] as? Int,
              let pageOrigin = inspection["origin"] as? String
        else { throw VaultError.message("The extension returned an incomplete answer.") }
        guard let origin = Origin.normalize(pageOrigin) else {
            throw VaultError.message("Refusing to fill on \(pageOrigin): only https pages (and localhost for development) are allowed.")
        }

        // 2. Pick the account: exact origin match only.
        let saved = Vault.entries(origin: origin)
        let accounts = saved.map(\.username)
        guard !accounts.isEmpty else {
            throw VaultError.message("No saved login for \(origin). The user can add one on Passhand's settings page (click the Passhand icon in Chrome) or in a terminal with: passhand add \(origin) <username>")
        }
        let user: String
        if let requested = username, !requested.isEmpty {
            guard accounts.contains(requested) else {
                throw VaultError.message("No saved login for \(requested) on \(origin). Saved usernames: \(accounts.joined(separator: ", ")).")
            }
            user = requested
        } else if accounts.count == 1 {
            user = accounts[0]
        } else {
            throw VaultError.message("Several logins are saved for \(origin): \(accounts.joined(separator: ", ")). Call fill_login again with the username to use.")
        }

        // 3. Find the fields: page heuristics first, local model only for odd forms.
        let fields = inspection["fields"] as? [[String: Any]] ?? []
        let guess = inspection["guess"] as? [String: Any] ?? [:]
        var usernameRef = guess["username_ref"] as? String
        var passwordRef = guess["password_ref"] as? String

        let config = Config.load()
        if usernameRef == nil, passwordRef == nil, config.modelFallback, !fields.isEmpty {
            let picked = FieldPicker.pick(fields: fields, config: config)
            usernameRef = picked.username
            passwordRef = picked.password
            Log.write("local model fallback used on \(origin)")
        }

        // Whatever picked them, a password only ever goes into a type=password input.
        var types: [String: String] = [:]
        for f in fields {
            if let ref = f["ref"] as? String, let type = f["type"] as? String { types[ref] = type }
        }
        if let ref = passwordRef, types[ref] != "password" { passwordRef = nil }
        if let ref = usernameRef, !["text", "email", "tel"].contains(types[ref] ?? "") { usernameRef = nil }
        guard usernameRef != nil || passwordRef != nil else {
            throw VaultError.message("Couldn't find a login form on this page. Make sure the sign-in form is visible, then try again.")
        }

        // 4. Build the fill. Touch ID / Windows Hello when a password is involved, unless this login is marked auto.
        let autoFill = saved.first(where: { $0.username == user })?.auto ?? false
        var items: [[String: Any]] = []
        if let ref = usernameRef {
            items.append(["ref": ref, "kind": "username", "value": user])
        }
        if let ref = passwordRef {
            let host = URLComponents(string: origin)?.host ?? origin
            if autoFill {
                Log.write("auto login (no \(Auth.name)) for \(user) on \(origin)")
            } else {
                try Auth.confirm("fill the password for \(user) on \(host)")
            }
            let secret = try Vault.password(origin: origin, username: user)
            items.append(["ref": ref, "kind": "password", "value": secret])
        }

        // 5. Fill. The extension re-checks the tab's origin right before writing.
        let result = try ExtensionLink.shared.call([
            "cmd": "fill",
            "tab_id": tabId,
            "expected_origin": pageOrigin,
            "items": items,
            "submit": submit,
        ])

        let filled = result["filled"] as? [String] ?? []
        Log.write("filled \(filled.joined(separator: "+")) for \(user) on \(origin)")
        var out: [String: Any] = [
            "origin": origin,
            "username": user,
            "filled": filled,
            "submitted": result["submitted"] as? Bool ?? false,
        ]
        if let note = result["submit_note"] as? String { out["submit_note"] = note }
        return out
    }
}
