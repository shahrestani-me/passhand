import Foundation
#if os(Windows)
import WinSDK
#endif

/// Minimal MCP server over stdio (newline-delimited JSON-RPC). Any MCP client can start it (Claude desktop, Claude Code, Cursor, ...).
/// It never touches a password: it forwards "fill this tab" to the native host and relays the outcome.
enum MCPServer {
    private static let outputLock = NSLock()

    /// Keep in step with "Using Passhand as an agent" in AGENTS.md: agents outside this repository only see this text.
    static let instructions = """
    Use fill_login whenever a page asks for a username and password. It fills credentials from the \
    user's \(Vault.storeName) (with \(Auth.name), or automatically for logins the user marked as auto); \
    you never see the password.

    1. Call fill_login with the tab's current page_url and, whenever your browser tools give you one, its \
    tab_id. Without tab_id, Passhand refuses if several tabs show the same URL.
    2. If it reports several saved accounts, call it again with username.
    3. After "Filled …", click the page's sign-in button yourself. Prefer that over submit: true.
    4. Two-step logins (email page, then password page): call fill_login once on each page.
    5. If it reports no saved login, tell the user to add one on Passhand's settings page (the Passhand \
    icon in Chrome) or with `passhand add <site> <username>`. Never ask the user to paste a password into \
    the chat, and never type one yourself. Don't open or use the settings page; managing logins is the user's job.
    6. 2FA codes, passkeys, CAPTCHAs, sign-up and change-password forms are out of scope. Hand them back to the user.

    list_saved_logins shows which sites and usernames exist and how each one fills: `auto` fills without \
    asking, `touch id` waits for the user to approve each fill, so it can't finish while they're away. It \
    never shows passwords.
    """

    static let tools: [[String: Any]] = [
        [
            "name": "fill_login",
            "description": """
            Fill the saved username and password into the login form of an open Chrome tab. A local helper \
            looks the login up in the \(Vault.storeName) by the tab's real origin (asking the user for \(Auth.name) \
            unless that login is marked for automatic filling) and types it into the page directly — the \
            password is never returned to you. Call this on a \
            sign-in page instead of typing credentials. Afterwards click the sign-in/continue button yourself. \
            For two-step logins (email page, then password page) call it once on each page.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "page_url": [
                        "type": "string",
                        "description": "Full URL of the login page, exactly as it is currently open in the tab.",
                    ] as [String: Any],
                    "username": [
                        "type": "string",
                        "description": "Optional. Which saved account to use when several are saved for the site.",
                    ] as [String: Any],
                    "submit": [
                        "type": "boolean",
                        "description": "Optional. Also submit the form after filling. Default false; prefer clicking the button yourself.",
                    ] as [String: Any],
                    "tab_id": [
                        "type": "integer",
                        "description": "Optional but recommended: the id of the browser tab the login page is in, when your browser tools give you one. Prevents filling the wrong tab when several tabs show the same URL.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["page_url"],
            ] as [String: Any],
        ],
        [
            "name": "list_saved_logins",
            "description": """
            List the sites and usernames saved in the user's local vault, one per line as \
            `origin  —  username  —  fill mode`. The fill mode is `auto` (fill_login fills without asking) or \
            `touch id` (each fill waits up to 2 minutes for the user to approve with Touch ID, so it can't \
            finish unattended). Passwords are never included.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
        ],
    ]

    static func run() -> Never {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            handle(message)
        }
        exit(0)
    }

    private static func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id, !(id is NSNull) else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func sendError(_ id: Any?, _ code: Int, _ message: String) {
        guard let id, !(id is NSNull) else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]])
    }

    private static func handle(_ message: [String: Any]) {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()] as [String: Any],
                "serverInfo": ["name": "passhand", "version": "0.4.0"],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            // Off the main loop: a fill can wait on Touch ID / Windows Hello for a while.
            DispatchQueue.global().async {
                let (text, isError) = MCPServer.runTool(name, args)
                MCPServer.reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
            }
        default:
            if !method.hasPrefix("notifications/") {
                sendError(id, -32601, "Method not found: \(method)")
            }
        }
    }

    private static func runTool(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        switch name {
        case "list_saved_logins":
            let entries = Vault.list()
            if entries.isEmpty {
                return ("No logins are saved yet. The user can add one on Passhand's settings page (click the Passhand icon in Chrome) or in a terminal with: passhand add <site> <username>", false)
            }
            return (entries.map { "\($0.origin)  —  \($0.username)  —  \($0.auto ? "auto" : "touch id")" }.joined(separator: "\n"), false)

        case "fill_login":
            guard let pageURL = args["page_url"] as? String, !pageURL.isEmpty else {
                return ("page_url is required.", true)
            }
            var request: [String: Any] = [
                "op": "fill_login",
                "page_url": pageURL,
                "submit": args["submit"] as? Bool ?? false,
            ]
            if let user = args["username"] as? String, !user.isEmpty { request["username"] = user }
            if let tab = args["tab_id"] as? Int { request["tab_id"] = tab }
            do {
                let response = try SocketClient.request(request, timeout: 120)
                guard response["ok"] as? Bool == true else {
                    return (response["error"] as? String ?? "Unknown error from the vault helper.", true)
                }
                return (summary(response), false)
            } catch {
                return ("\(error)", true)
            }

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private static func summary(_ r: [String: Any]) -> String {
        let user = r["username"] as? String ?? "the saved account"
        let origin = r["origin"] as? String ?? "this site"
        let filled = r["filled"] as? [String] ?? []
        var text: String
        if filled.contains("password") {
            text = "Filled the \(filled.joined(separator: " and ")) for \(user) on \(origin)."
        } else {
            text = "Filled only the username for \(user) on \(origin) — this page has no password field yet. Click Next/Continue, then call fill_login again on the password page."
        }
        if r["submitted"] as? Bool == true {
            text += " The form was submitted."
        } else if let note = r["submit_note"] as? String {
            text += " " + note
        } else if filled.contains("password") {
            text += " Now click the sign-in button."
        }
        return text
    }
}
