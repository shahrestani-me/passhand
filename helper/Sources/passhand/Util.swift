import Foundation
#if os(Windows)
import WinSDK
#else
import Security
#endif

enum VaultError: Error, CustomStringConvertible {
    #if os(Windows)
    case windows(String, DWORD)
    #else
    case keychain(OSStatus)
    #endif
    case message(String)
    case authFailed

    var description: String {
        switch self {
        #if os(Windows)
        case .windows(let what, let code):
            return "\(what) failed (Windows error \(code)): \(windowsErrorText(code))"
        #else
        case .keychain(let status):
            let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
            return "Keychain error \(status): \(text)"
        #endif
        case .message(let m):
            return m
        case .authFailed:
            return "\(Auth.name) was not confirmed, so nothing was filled."
        }
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(Windows)
    // %LOCALAPPDATA%\passhand: per user, never roamed to other machines.
    static let support = known("LOCALAPPDATA", "AppData/Local").appendingPathComponent("passhand", isDirectory: true)
    #else
    static let support = home.appendingPathComponent("Library/Application Support/passhand", isDirectory: true)
    #endif
    static var config: URL { support.appendingPathComponent("config.json") }
    static var log: URL { support.appendingPathComponent("host.log") }

    #if os(Windows)
    /// Claude desktop's config in %APPDATA%\Claude, or in its package folder when it was installed as an
    /// MSIX package and already keeps its config there.
    static let claudeConfig: URL = {
        let packages = known("LOCALAPPDATA", "AppData/Local").appendingPathComponent("Packages", isDirectory: true)
        let packaged = ((try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? [])
            .filter { $0.hasPrefix("Claude_") }
            .map { packages.appendingPathComponent("\($0)/LocalCache/Roaming/Claude/claude_desktop_config.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return packaged ?? known("APPDATA", "AppData/Roaming").appendingPathComponent("Claude/claude_desktop_config.json")
    }()

    private static func known(_ variable: String, _ fallback: String) -> URL {
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }

    static func ensure() {
        // %LOCALAPPDATA% is already private to this user.
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    #else
    static let claudeConfig = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    static func ensure() {
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    #endif
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

#if os(Windows)
/// Reads a line from the console without echoing it. Piped input (no console) is read as is.
func readSecret(_ prompt: String) -> String? {
    FileHandle.standardError.write(prompt.data(using: .utf8)!)
    let input = GetStdHandle(STD_INPUT_HANDLE)
    var original: DWORD = 0
    guard GetConsoleMode(input, &original) else { return readLine(strippingNewline: true) }
    SetConsoleMode(input, original & ~DWORD(ENABLE_ECHO_INPUT))
    defer {
        SetConsoleMode(input, original)
        FileHandle.standardError.write("\n".data(using: .utf8)!)
    }
    // ReadConsoleW, so characters outside the console's code page survive.
    var units: [WCHAR] = []
    var buffer = [WCHAR](repeating: 0, count: 256)
    while units.last != 0x0A {
        var got: DWORD = 0
        guard ReadConsoleW(input, &buffer, DWORD(buffer.count), &got, nil), got > 0 else { break }
        units.append(contentsOf: buffer[..<Int(got)])
    }
    while let last = units.last, last == 0x0A || last == 0x0D { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}

func windowsErrorText(_ code: DWORD) -> String {
    var buffer = [WCHAR](repeating: 0, count: 512)
    let flags = DWORD(FORMAT_MESSAGE_FROM_SYSTEM) | DWORD(FORMAT_MESSAGE_IGNORE_INSERTS)
    let length = FormatMessageW(flags, nil, code, 0, &buffer, DWORD(buffer.count), nil)
    guard length > 0 else { return "unknown" }
    return String(decoding: buffer[..<Int(length)], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Chrome's native messaging pipes, through the raw handles: the C runtime's text mode would turn every
/// 0x0A byte in a frame into 0x0D 0x0A.
enum StdStream {
    static func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var got: DWORD = 0
        guard ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer, DWORD(count), &got, nil) else { return -1 }
        return Int(got)
    }

    static func write(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress else { return }
        let output = GetStdHandle(STD_OUTPUT_HANDLE)
        var offset = 0
        while offset < buffer.count {
            var wrote: DWORD = 0
            guard WriteFile(output, base + offset, DWORD(buffer.count - offset), &wrote, nil), wrote > 0 else { return }
            offset += Int(wrote)
        }
    }
}
#else
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

/// Chrome's native messaging pipes.
enum StdStream {
    static func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        Darwin.read(STDIN_FILENO, buffer, count)
    }

    static func write(_ buffer: UnsafeRawBufferPointer) {
        writeAll(STDOUT_FILENO, buffer)
    }
}
#endif
