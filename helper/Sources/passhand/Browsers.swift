import Foundation

/// The browsers running Passhand right now, as the MCP side and `passhand doctor` see them. Every browser
/// (every Chrome profile, in fact) starts its own native host, listening on sockets/<pid>.sock.
enum Browsers {
    struct Host {
        let pid: pid_t
        let socket: String
    }

    /// The hosts that are running. A socket left by a host that was killed is deleted here, but only when
    /// no process has its pid any more, so a running host's socket is never touched.
    static func hosts() -> [Host] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.sockets.path)) ?? []
        var hosts: [Host] = []
        for name in names.sorted() where name.hasSuffix(".sock") {
            guard let pid = pid_t(name.dropLast(5)), pid > 0 else { continue }
            let path = Paths.sockets.appendingPathComponent(name).path
            if kill(pid, 0) != 0 && errno == ESRCH {
                var st = stat()
                if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
                continue
            }
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

    /// Sends fill_login to the one browser that has the tab. The same page open in two browsers is
    /// refused, like two tabs in one: tab ids are numbered per browser, so they can't tell them apart.
    static func fillLogin(_ request: [String: Any]) throws -> [String: Any] {
        let hosts = hosts()
        guard !hosts.isEmpty else { throw VaultError.message(SocketClient.notRunning) }
        if hosts.count == 1 { return try SocketClient.request(request, socket: hosts[0].socket) }

        let pageURL = request["page_url"] as? String ?? ""
        var locate: [String: Any] = ["op": "locate", "page_url": pageURL]
        if let tab = request["tab_id"] { locate["tab_id"] = tab }
        let answers = ask(hosts, locate, timeout: 10)

        // The best kind of match wins, as it does within one browser: tab_id, then the exact URL, then origin and path.
        let rank = ["tab_id": 0, "url": 1, "path": 2]
        var found: [(host: Host, browser: String, rank: Int, count: Int)] = []
        var answered = 0
        var errors: [String] = []
        for (host, answer) in zip(hosts, answers) {
            guard let answer else { continue }
            guard answer["ok"] as? Bool == true else {
                if let error = answer["error"] as? String { errors.append(error) }
                continue
            }
            answered += 1
            if let by = answer["by"] as? String, let r = rank[by], let count = answer["count"] as? Int, count > 0 {
                found.append((host, answer["browser"] as? String ?? "a browser", r, count))
            }
        }

        guard let best = found.map(\.rank).min() else {
            if answered == 0, let error = errors.first { throw VaultError.message(error) }
            guard answered > 0 else { throw VaultError.message(SocketClient.notRunning) }
            let silent = hosts.count - answered
            var text = "No open tab matches \(pageURL) in any browser running Passhand. Pass the URL of the login tab exactly as it is open now."
            if silent > 0 { text += " (\(silent) of \(hosts.count) browsers didn't answer; passhand doctor shows which.)" }
            throw VaultError.message(text)
        }
        let matches = found.filter { $0.rank == best }
        guard matches.count == 1 else {
            let total = matches.reduce(0) { $0 + $1.count }
            let browsers = matches.map(\.browser).joined(separator: ", ")
            throw VaultError.message("\(total) tabs are open on \(pageURL) in \(matches.count) browsers (\(browsers)), so nothing was filled (it could be the wrong tab). " +
                "tab_id can't tell browsers apart. Make this tab's URL unique (for example add ?login=1), or close the other tabs.")
        }
        return try SocketClient.request(request, socket: matches[0].host.socket)
    }
}
