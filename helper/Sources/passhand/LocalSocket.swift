import Foundation
#if os(Windows)
import WinSDK
#endif

// The local socket between the MCP process and the native host. It never carries a password.
// macOS: a Unix socket, 0600 in a 0700 folder, plus a peer uid check.
// Windows: a named pipe whose DACL admits only this user. Pipe names are machine-wide, so the server
// checks the client's user and the client checks the server's, so another user can't squat the name.

/// Used by the MCP side to talk to the native host that Chrome keeps running.
enum SocketClient {
    static let notRunning = "The Passhand Chrome extension isn't connected. Ask the user to open Chrome and check that the Passhand extension is enabled (passhand doctor shows the details)."

    static func request(_ obj: [String: Any], timeout: Int = 120) throws -> [String: Any] {
        let connection = try LocalSocket.connect(timeout: timeout)
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        connection.write(data)
        guard let line = connection.readLine(),
              let resp = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { throw VaultError.message("No answer from the vault helper (timed out, or the \(Auth.name) prompt was left open).") }
        return resp
    }
}

#if os(Windows)

/// One connection on the pipe. Overlapped I/O, so a read can time out.
final class LocalConnection {
    private let handle: HANDLE
    private let timeout: DWORD

    init(handle: HANDLE, timeout: DWORD) {
        self.handle = handle
        self.timeout = timeout
    }

    deinit { CloseHandle(handle) }

    func readLine(limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            guard let n = chunk.withUnsafeMutableBytes({ transfer(write: false, $0.baseAddress!, $0.count) }), n > 0
            else { break }
            if let newline = chunk[..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: chunk[..<newline])
                return data
            }
            data.append(contentsOf: chunk[..<n])
        }
        return data.isEmpty ? nil : data
    }

    func write(_ data: Data) {
        var bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard let n = bytes.withUnsafeMutableBytes({ transfer(write: true, $0.baseAddress! + offset, $0.count - offset) }), n > 0
            else { return }
            offset += n
        }
        // Closing a pipe can drop data the other end hasn't read yet.
        FlushFileBuffers(handle)
    }

    /// One ReadFile or WriteFile, waited for up to `timeout`. Returns the bytes moved, or nil.
    private func transfer(write: Bool, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int? {
        guard let event = CreateEventW(nil, true, false, nil) else { return nil }
        defer { CloseHandle(event) }
        var overlapped = OVERLAPPED()
        overlapped.hEvent = event
        let started = write ? WriteFile(handle, buffer, DWORD(count), nil, &overlapped)
                            : ReadFile(handle, buffer, DWORD(count), nil, &overlapped)
        if !started && GetLastError() != DWORD(ERROR_IO_PENDING) { return nil }
        if WaitForSingleObject(event, timeout) != WAIT_OBJECT_0 { CancelIoEx(handle, &overlapped) }
        var moved: DWORD = 0
        guard GetOverlappedResult(handle, &overlapped, &moved, true) else { return nil }
        return Int(moved)
    }
}

enum LocalSocket {
    static var path: String { #"\\.\pipe\passhand-"# + (WindowsUser.current ?? "unknown") }

    /// Accepts this user's processes and hands each connection to `handle` on its own thread.
    static func listen(_ handle: @escaping (LocalConnection) -> Void) {
        guard let user = WindowsUser.current else { Log.write("could not look up the current user"); return }
        var descriptor: PSECURITY_DESCRIPTOR?
        // Protected DACL with a single entry: full access for this user, nobody else.
        let built = "D:P(A;;GA;;;\(user))".withCString(encodedAs: UTF16.self) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard built else { Log.write("could not build the pipe's security descriptor (error \(GetLastError()))"); return }
        var attributes = SECURITY_ATTRIBUTES()
        attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        attributes.lpSecurityDescriptor = descriptor

        guard var pipe = instance(&attributes, first: true) else {
            Log.write("could not create the pipe (error \(GetLastError())); is another Passhand helper running, e.g. for a second Chrome profile?")
            return
        }
        Thread.detachNewThread {
            while true {
                if waitForClient(pipe), let pid = clientProcess(pipe), WindowsUser.owns(process: pid) {
                    let connection = LocalConnection(handle: pipe, timeout: INFINITE)
                    Thread.detachNewThread { handle(connection) }
                } else {
                    DisconnectNamedPipe(pipe)
                    CloseHandle(pipe)
                }
                guard let next = instance(&attributes, first: false) else {
                    Log.write("could not create the next pipe instance (error \(GetLastError()))")
                    return
                }
                pipe = next
            }
        }
    }

    static func connect(timeout: Int) throws -> LocalConnection {
        // SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: whoever is on the other end can't act as us.
        let identifyOnly: DWORD = 0x0010_0000 | 0x0001_0000
        func open() -> HANDLE? {
            let h = path.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING),
                            DWORD(FILE_FLAG_OVERLAPPED) | identifyOnly, nil)
            }
            return h == INVALID_HANDLE_VALUE ? nil : h
        }
        var pipe = open()
        if pipe == nil, GetLastError() == DWORD(ERROR_PIPE_BUSY) {
            _ = path.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, 5000) }
            pipe = open()
        }
        guard let pipe else { throw VaultError.message(SocketClient.notRunning) }
        var pid: ULONG = 0
        guard GetNamedPipeServerProcessId(pipe, &pid), WindowsUser.owns(process: DWORD(pid)) else {
            CloseHandle(pipe)
            throw VaultError.message("Passhand's pipe is held by a process of another user, so nothing was sent.")
        }
        return LocalConnection(handle: pipe, timeout: DWORD(timeout * 1000))
    }

    static func cleanUp() {}

    private static func instance(_ attributes: inout SECURITY_ATTRIBUTES, first: Bool) -> HANDLE? {
        // The first instance must be new, so a pipe someone else created already isn't joined.
        let openMode = DWORD(PIPE_ACCESS_DUPLEX) | DWORD(FILE_FLAG_OVERLAPPED) | (first ? DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE) : 0)
        let pipeMode = DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT) | DWORD(PIPE_REJECT_REMOTE_CLIENTS)
        let h = path.withCString(encodedAs: UTF16.self) {
            CreateNamedPipeW($0, openMode, pipeMode, DWORD(PIPE_UNLIMITED_INSTANCES), 65536, 65536, 0, &attributes)
        }
        return h == INVALID_HANDLE_VALUE ? nil : h
    }

    private static func waitForClient(_ pipe: HANDLE) -> Bool {
        guard let event = CreateEventW(nil, true, false, nil) else { return false }
        defer { CloseHandle(event) }
        var overlapped = OVERLAPPED()
        overlapped.hEvent = event
        if ConnectNamedPipe(pipe, &overlapped) { return true }
        switch GetLastError() {
        case DWORD(ERROR_PIPE_CONNECTED):
            return true
        case DWORD(ERROR_IO_PENDING):
            var unused: DWORD = 0
            return GetOverlappedResult(pipe, &overlapped, &unused, true)
        default:
            return false
        }
    }

    private static func clientProcess(_ pipe: HANDLE) -> DWORD? {
        var pid: ULONG = 0
        return GetNamedPipeClientProcessId(pipe, &pid) ? DWORD(pid) : nil
    }
}

/// Which Windows user a process runs as, by SID.
enum WindowsUser {
    /// This process's user, like "S-1-5-21-…".
    static let current: String? = sid(of: GetCurrentProcess())

    static func owns(process pid: DWORD) -> Bool {
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return false }
        defer { CloseHandle(process) }
        guard let user = sid(of: process) else { return false }
        return user == current
    }

    private static func sid(of process: HANDLE) -> String? {
        var token: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { CloseHandle(token) }
        var needed: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &needed)
        guard needed > 0 else { return nil }
        let size = needed
        var buffer = [UInt8](repeating: 0, count: Int(size))
        return buffer.withUnsafeMutableBytes { raw -> String? in
            guard GetTokenInformation(token, TokenUser, raw.baseAddress, size, &needed) else { return nil }
            let user = raw.load(as: TOKEN_USER.self)
            var text: LPWSTR?
            guard ConvertSidToStringSidW(user.User.Sid, &text), let text else { return nil }
            defer { LocalFree(text) }
            return String(decodingCString: text, as: UTF16.self)
        }
    }
}

#else

final class LocalConnection {
    private let fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    func readLine(limit: Int = 1 << 20) -> Data? {
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

    func write(_ data: Data) {
        data.withUnsafeBytes { writeAll(fd, $0) }
    }
}

enum LocalSocket {
    static var path: String { Paths.support.appendingPathComponent("vault.sock").path }

    /// Accepts this user's processes and hands each connection to `handle` on its own thread.
    static func listen(_ handle: @escaping (LocalConnection) -> Void) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = UnixAddress.make(path) else { Log.write("could not create socket"); return }
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Log.write("could not listen on socket (errno \(errno))"); return }
        chmod(path, 0o600)

        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var uid: uid_t = 0
                var gid: gid_t = 0
                if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                    close(client)
                    continue
                }
                let connection = LocalConnection(fd: client)
                Thread.detachNewThread { handle(connection) }
            }
        }
    }

    static func connect(timeout: Int) throws -> LocalConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultError.message("Could not open a local socket") }
        let connection = LocalConnection(fd: fd)
        guard var addr = UnixAddress.make(path) else { throw VaultError.message("Socket path too long") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw VaultError.message(SocketClient.notRunning) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return connection
    }

    static func cleanUp() { unlink(path) }
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

#endif
