import Foundation

/// The browsers running Passhand right now, as the MCP side and `passhand doctor` see them. Every browser
/// (every Chrome profile, in fact) starts its own native host, listening on sockets/<pid>-<random>.sock.
enum Browsers {
    struct Host {
        let pid: pid_t
        let socket: String
    }

    /// The hosts that are running. A socket nobody listens on is left by a host that was killed, and is
    /// deleted here. A host only gives its socket a .sock name once it listens, and the random part means
    /// a new host never reuses an old name, so a running host's socket is never deleted.
    static func hosts() -> [Host] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.sockets.path)) ?? []
        var hosts: [Host] = []
        for name in names.sorted() where name.hasSuffix(".sock") {
            guard let pid = pid_t(name.prefix(while: \.isNumber)), pid > 0 else { continue }
            let path = Paths.sockets.appendingPathComponent(name).path
            do {
                close(try SocketClient.connect(path))
            } catch is SocketClient.NotListening {
                var st = stat()
                if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
                continue
            } catch {}
            hosts.append(Host(pid: pid, socket: path))
        }
        return hosts
    }

    /// Sends `request` to every host at once. An answer is nil where a host couldn't be reached.
    static func ask(_ hosts: [Host], _ request: [String: Any], timeout: Int) -> [[String: Any]?] {
        var answers = [[String: Any]?](repeating: nil, count: hosts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { i in
            let answer = try? SocketClient.request(request, socket: hosts[i].socket, timeout: timeout)
            lock.lock(); answers[i] = answer; lock.unlock()
        }
        return answers
    }

    /// "Google Chrome (helper pid 123)": two Chrome profiles have the same browser name.
    static func label(_ host: Host, _ answer: [String: Any]?) -> String {
        "\(answer?["browser"] as? String ?? "a browser") (helper pid \(host.pid))"
    }

    /// Sends fill_login to the browser that has the tab. It fills only when exactly one browser has the
    /// page and every browser answered; anything else could be the wrong browser, so it's refused. Tab ids
    /// can't settle it: each browser numbers its tabs separately.
    static func fillLogin(_ request: [String: Any]) throws -> [String: Any] {
        let hosts = hosts()
        guard !hosts.isEmpty else { throw VaultError.message(SocketClient.notRunning) }
        if hosts.count == 1 { return try SocketClient.request(request, socket: hosts[0].socket) }

        let pageURL = request["page_url"] as? String ?? ""
        var locate: [String: Any] = ["op": "locate", "page_url": pageURL]
        if let tab = request["tab_id"] { locate["tab_id"] = tab }
        let answers = ask(hosts, locate, timeout: 10)

        var found: [(host: Host, label: String)] = []
        var silent: [String] = []
        var errors: [String] = []
        for (host, answer) in zip(hosts, answers) {
            guard let answer, answer["ok"] as? Bool == true else {
                silent.append(label(host, answer))
                if let error = answer?["error"] as? String { errors.append(error) }
                continue
            }
            if answer["count"] as? Int ?? 0 > 0 { found.append((host, label(host, answer))) }
        }

        // An error every browser gives (an invalid page_url, say) is the answer itself.
        guard silent.count < hosts.count else { throw VaultError.message(errors.first ?? SocketClient.notRunning) }
        guard silent.isEmpty else {
            throw VaultError.message("Nothing was filled: Passhand in \(silent.joined(separator: ", ")) didn't answer, and it could have this page open too. " +
                "Try again in a moment. If it keeps happening, the user can reload the Passhand extension in that browser (passhand doctor shows which browsers answer).")
        }
        guard !found.isEmpty else {
            throw VaultError.message("No open tab matches \(pageURL) in any browser running Passhand. Pass the URL of the login tab exactly as it is open now.")
        }
        guard found.count == 1 else {
            throw VaultError.message("\(pageURL) is open in \(found.count) browsers (\(found.map(\.label).joined(separator: ", "))), so nothing was filled (it could be the wrong one). " +
                "tab_id can't tell browsers apart. Close the page in all but one of them, then try again.")
        }
        do {
            return try SocketClient.request(request, socket: found[0].host.socket)
        } catch is SocketClient.NotListening {
            throw VaultError.message("\(found[0].label) closed before the login could be filled, so nothing was filled. Open the page again and retry.")
        }
    }
}
