import Foundation
import Security

enum VaultError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case message(String)
    case authFailed

    var description: String {
        switch self {
        case .keychain(let status):
            let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
            return "Keychain error \(status): \(text)"
        case .message(let m):
            return m
        case .authFailed:
            return "Touch ID was not confirmed, so nothing was filled."
        }
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// PASSHAND_DIR moves this folder (sockets, config, log) somewhere else, for tests. The Keychain is unaffected.
    static let support: URL = {
        if let dir = ProcessInfo.processInfo.environment["PASSHAND_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/passhand", isDirectory: true)
    }()
    /// One socket per native host, named <pid>.sock: every browser (every Chrome profile) starts its own host.
    static var sockets: URL { support.appendingPathComponent("sockets", isDirectory: true) }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var log: URL { support.appendingPathComponent("host.log") }
    static let claudeConfig = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    static func ensure() {
        for dir in [support, sockets] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }
}

struct Config {
    var ollamaURL = "http://127.0.0.1:11434"
    var model = "qwen2.5:3b"
    var modelFallback = true

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: Paths.config),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return c }
        if let v = o["ollama_url"] as? String { c.ollamaURL = v }
        if let v = o["model"] as? String { c.model = v }
        if let v = o["model_fallback"] as? Bool { c.modelFallback = v }
        return c
    }
}

/// Origins are the vault's lookup key: scheme + host (+ non-default port).
enum Origin {
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost") || host.hasSuffix(".test")
    }

    /// Returns nil for anything that is not https (http is allowed only for local development hosts).
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty
        else { return nil }
        guard scheme == "https" || (scheme == "http" && isLocal(host)) else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = c.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            origin += ":\(port)"
        }
        return origin
    }

    /// Like normalize, but for saving a login: the host must be a real domain (or a local development
    /// host) and the input can't carry a user name, so "alice" or "alice@example.com" typed into the site
    /// field isn't saved as a site.
    static func forSaving(_ input: String) -> String? {
        guard let origin = normalize(input) else { return nil }
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), c.user == nil, c.password == nil,
              let host = c.host?.lowercased()
        else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard isLocal(host) || (labels.count >= 2 && !labels.contains(where: \.isEmpty)) else { return nil }
        return origin
    }
}

enum Log {
    static func write(_ text: String) {
        Paths.ensure()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Paths.log) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: Paths.log)
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Reads a line from the terminal without echoing it.
func readSecret(_ prompt: String) -> String? {
    FileHandle.standardError.write(prompt.data(using: .utf8)!)
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var silent = original
    silent.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &silent)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        FileHandle.standardError.write("\n".data(using: .utf8)!)
    }
    return readLine(strippingNewline: true)
}

func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) {
    guard let base = buffer.baseAddress else { return }
    var offset = 0
    while offset < buffer.count {
        let n = Darwin.write(fd, base + offset, buffer.count - offset)
        if n <= 0 { return }
        offset += n
    }
}

func readLineFD(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < limit {
        let n = read(fd, &byte, 1)
        if n <= 0 { break }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    return data.isEmpty ? nil : data
}

enum UnixAddress {
    static func make(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// Used by the MCP side to talk to the native host that Chrome keeps running.
enum SocketClient {
    static let notRunning = "The Passhand Chrome extension isn't connected. Ask the user to open Chrome and check that the Passhand extension is enabled (passhand doctor shows the details)."

    static func request(_ obj: [String: Any], socket path: String, timeout: Int = 120) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.message("Could not open a local socket") }
        defer { close(fd) }
        guard var addr = UnixAddress.make(path) else { throw VaultError.message("Socket path too long") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw VaultError.message(notRunning) }
        // The folder is 0700, but check the other end as well: it must be one of this user's processes.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw VaultError.message("Passhand's socket is held by another user's process, so nothing was sent.")
        }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        data.withUnsafeBytes { writeAll(fd, $0) }
        guard let line = readLineFD(fd),
              let resp = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { throw VaultError.message("No answer from the vault helper (timed out, or the Touch ID prompt was left open).") }
        return resp
    }
}
