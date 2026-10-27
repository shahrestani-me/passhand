import Foundation

enum CLI {
    static func help() {
        print("""
        passhand — lets AI agents sign in to websites without ever seeing your passwords

        Usage:
          passhand add <site> <username> [--auto]   Save a login (asks for the password, nothing is echoed)
          passhand auto <site> <username> on|off    Fill this login without Touch ID (on) or with it (off)
          passhand list                             Show saved sites, usernames and fill mode
          passhand remove <site> <username>         Delete a saved login
          passhand doctor                           Check that Chrome, the extension and the MCP client are connected

        Fill modes:
          touch id  (default)  every password fill asks for Touch ID
          auto                 fills unattended; use it for test and QA accounts. Turning it on asks for Touch ID once.

        Examples:
          passhand add github.com you@example.com
          passhand add staging.myapp.com qa-tester@example.com --auto
        """)
    }

    static func setAuto(_ args: [String]) {
        guard args.count == 3, let origin = Origin.normalize(args[0]), ["on", "off"].contains(args[2]) else {
            fail("Usage: passhand auto <site> <username> on|off")
        }
        let user = args[1]
        guard Vault.entries(origin: origin).contains(where: { $0.username == user }) else {
            fail("Nothing saved for \(user) on \(origin).")
        }
        let on = args[2] == "on"
        do {
            if on { try Auth.confirm("let AI agents fill \(user) on \(origin) without asking") }
            try Vault.setAuto(origin: origin, username: user, auto: on)
            print(on ? "\(user) on \(origin) now fills automatically (no Touch ID)."
                     : "\(user) on \(origin) asks for Touch ID again.")
        } catch {
            fail("\(error)")
        }
    }

    static func add(_ rawArgs: [String]) {
        let auto = rawArgs.contains("--auto")
        let args = rawArgs.filter { $0 != "--auto" }
        guard args.count == 2 else { fail("Usage: passhand add <site> <username> [--auto]") }
        guard let origin = Origin.forSaving(args[0]) else {
            fail("\(args[0]) isn't accepted: enter the site's full address, like example.com. Only https sites (and localhost / *.test for development) can be saved.")
        }
        let user = args[1]
        guard let first = readSecret("Password for \(user) on \(origin): "), !first.isEmpty else {
            fail("No password entered. Nothing saved.")
        }
        guard let second = readSecret("Repeat it: "), first == second else {
            fail("The two entries didn't match. Nothing saved.")
        }
        do {
            if auto { try Auth.confirm("let AI agents fill \(user) on \(origin) without asking") }
            try Vault.save(origin: origin, username: user, password: first, auto: auto)
            print("Saved \(user) for \(origin)" + (auto ? " — fills automatically (no Touch ID)." : " — asks for Touch ID on each fill."))
        } catch {
            fail("\(error)")
        }
    }

    static func list() {
        let entries = Vault.list()
        if entries.isEmpty {
            print("No logins saved yet. Add one with: passhand add <site> <username>")
            return
        }
        for e in entries { print("\(e.origin)\t\(e.username)\t\(e.auto ? "auto" : "touch id")") }
    }

    static func remove(_ args: [String]) {
        guard args.count == 2, let origin = Origin.normalize(args[0]) else {
            fail("Usage: passhand remove <site> <username>")
        }
        if Vault.remove(origin: origin, username: args[1]) {
            print("Removed \(args[1]) for \(origin).")
        } else {
            fail("Nothing saved for \(args[1]) on \(origin).")
        }
    }

    static func purge() {
        let entries = Vault.list()
        for e in entries { Vault.remove(origin: e.origin, username: e.username) }
        print("Removed \(entries.count) saved login(s) from the Keychain.")
    }

    static func doctor() {
        print("Helper binary:   \(CommandLine.arguments[0])")
        print("Saved logins:    \(Vault.list().count)")

        // One line per browser (or Chrome profile) running Passhand.
        let hosts = Browsers.hosts()
        if hosts.isEmpty {
            print("Chrome helper:   not reachable ✗ — open Chrome and check the Passhand extension is enabled (after ./install.sh, reload it on chrome://extensions)")
        }
        for (i, (host, r)) in zip(hosts, Browsers.ask(hosts, ["op": "ping"], timeout: 8)).enumerated() {
            let label = (i == 0 ? "Chrome helper:" : "").padding(toLength: 17, withPad: " ", startingAt: 0)
            let browser = "\(r?["browser"] as? String ?? "?") (helper pid \(host.pid))"
            if r == nil {
                print("\(label)\(browser): not reachable ✗")
            } else if r?["extension"] as? Bool == true {
                print("\(label)\(browser): running, extension answering ✓")
            } else {
                print("\(label)\(browser): running, but the extension did not answer ✗")
            }
        }

        let claudeOK: Bool = {
            guard let d = try? Data(contentsOf: Paths.claudeConfig),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let servers = o["mcpServers"] as? [String: Any] else { return false }
            return servers["passhand"] != nil
        }()
        print("Claude desktop:  \(claudeOK ? "tool registered ✓ (restart Claude after installing)" : "not registered ✗ — run install.sh again")")

        let config = Config.load()
        if config.modelFallback {
            let up = FieldPicker.reachable(config)
            print("Local model:     \(config.model) at \(config.ollamaURL) — \(up ? "reachable ✓" : "not running (optional; only needed for unusual login forms)")")
        } else {
            print("Local model:     off")
        }
    }

    static func installClaudeConfig(_ args: [String]) {
        guard let binary = args.first else { fail("Usage: passhand install-claude-config <path-to-binary>") }
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.claudeConfig) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                fail("Couldn't parse \(Paths.claudeConfig.path). Add the passhand server by hand (see README).")
            }
            root = parsed
            try? data.write(to: Paths.claudeConfig.appendingPathExtension("bak"))
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["passhand"] = ["command": binary, "args": ["mcp"]] as [String: Any]
        root["mcpServers"] = servers
        writeClaudeConfig(root)
        print("Registered fill_login with Claude desktop (backup saved as claude_desktop_config.json.bak).")
    }

    static func uninstallClaudeConfig() {
        guard let data = try? Data(contentsOf: Paths.claudeConfig),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any],
              servers["passhand"] != nil
        else { return }
        servers["passhand"] = nil
        root["mcpServers"] = servers
        writeClaudeConfig(root)
        print("Removed passhand from Claude desktop config.")
    }

    private static func writeClaudeConfig(_ root: [String: Any]) {
        do {
            try FileManager.default.createDirectory(
                at: Paths.claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: Paths.claudeConfig)
        } catch {
            fail("Couldn't write \(Paths.claudeConfig.path): \(error)")
        }
    }
}
