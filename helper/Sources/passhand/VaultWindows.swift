#if os(Windows)
import Foundation
import WinSDK

/// The "box" on Windows: generic credentials in Windows Credential Manager.
/// target = "passhand:<origin> <username>" (an origin never contains a space), user name = username,
/// comment = fill mode. Unlike the macOS Keychain, Credential Manager doesn't limit which program may
/// read an item: anything running as you can (see SECURITY.md).
enum Vault {
    static let storeName = "Windows Credential Manager"
    static let prefix = "passhand:"
    static let autoMark = "fill:auto"
    static let promptMark = "fill:hello"

    static func target(_ origin: String, _ username: String) -> String { prefix + origin + " " + username }

    static func save(origin: String, username: String, password: String, auto: Bool) throws {
        var blob = Array(password.utf8)
        try write(origin: origin, username: username, comment: auto ? autoMark : promptMark, blob: &blob, flags: 0)
    }

    static func setAuto(origin: String, username: String, auto: Bool) throws {
        var none: [UInt8] = []
        // CRED_PRESERVE_CREDENTIAL_BLOB: change the comment, keep the saved password as it is.
        try write(origin: origin, username: username, comment: auto ? autoMark : promptMark, blob: &none, flags: 0x1)
    }

    private static func write(origin: String, username: String, comment: String, blob: inout [UInt8], flags: DWORD) throws {
        var error: DWORD = 0
        let ok = target(origin, username).withCString(encodedAs: UTF16.self) { target in
            username.withCString(encodedAs: UTF16.self) { user in
                comment.withCString(encodedAs: UTF16.self) { comment in
                    blob.withUnsafeMutableBufferPointer { bytes -> Bool in
                        var credential = CREDENTIALW()
                        credential.`Type` = DWORD(CRED_TYPE_GENERIC)
                        credential.TargetName = UnsafeMutablePointer(mutating: target)
                        credential.UserName = UnsafeMutablePointer(mutating: user)
                        credential.Comment = UnsafeMutablePointer(mutating: comment)
                        credential.CredentialBlobSize = DWORD(bytes.count)
                        credential.CredentialBlob = bytes.baseAddress
                        credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                        let written = CredWriteW(&credential, flags)
                        if !written { error = GetLastError() }
                        return written
                    }
                }
            }
        }
        for i in blob.indices { blob[i] = 0 }
        guard ok else { throw VaultError.windows("Saving to Credential Manager", error) }
    }

    static func list() -> [Entry] {
        var count: DWORD = 0
        var credentials: UnsafeMutablePointer<PCREDENTIALW?>?
        let ok = (prefix + "*").withCString(encodedAs: UTF16.self) { CredEnumerateW($0, 0, &count, &credentials) }
        guard ok, let credentials else { return [] }
        defer { CredFree(credentials) }
        return (0..<Int(count)).compactMap { i -> Entry? in
            guard let c = credentials[i]?.pointee, c.`Type` == DWORD(CRED_TYPE_GENERIC),
                  let rawTarget = c.TargetName, let rawUser = c.UserName else { return nil }
            let target = String(decodingCString: rawTarget, as: UTF16.self)
            let user = String(decodingCString: rawUser, as: UTF16.self)
            guard target.hasPrefix(prefix) else { return nil }
            let origin = String(target.dropFirst(prefix.count).prefix { $0 != " " })
            guard target == self.target(origin, user) else { return nil }
            let auto = c.Comment.map { String(decodingCString: $0, as: UTF16.self) } == autoMark
            return Entry(origin: origin, username: user, auto: auto)
        }
        .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }

    static func password(origin: String, username: String) throws -> String {
        var credential: PCREDENTIALW?
        var error: DWORD = 0
        let ok = target(origin, username).withCString(encodedAs: UTF16.self) { target -> Bool in
            let read = CredReadW(target, DWORD(CRED_TYPE_GENERIC), 0, &credential)
            if !read { error = GetLastError() }
            return read
        }
        guard ok, let credential else { throw VaultError.windows("Reading from Credential Manager", error) }
        defer { CredFree(credential) }
        let c = credential.pointee
        let bytes = UnsafeBufferPointer(start: c.CredentialBlob, count: Int(c.CredentialBlobSize))
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw VaultError.message("The saved password for \(username) on \(origin) can't be read. Save it again with passhand add.")
        }
        return value
    }

    @discardableResult
    static func remove(origin: String, username: String) -> Bool {
        target(origin, username).withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
    }
}

/// Windows Hello (face, fingerprint or PIN) before every password fill.
enum Auth {
    static let name = "Windows Hello"

    /// The Chrome window that started the native host (its --parent-window argument), so the prompt
    /// belongs to it.
    static var parentWindow: HWND?

    /// nil when Windows Hello can be asked for, otherwise why not.
    static func availability() -> String? {
        do {
            switch try UserConsent.availability() {
            case 0: return nil
            case 1: return "this PC has no Windows Hello device"
            case 2: return "Windows Hello isn't set up for you. Set up a PIN, fingerprint or face in Settings → Accounts → Sign-in options"
            case 3: return "Windows Hello is turned off by policy"
            case 4: return "Windows Hello is busy"
            case let other: return "unknown state \(other)"
            }
        } catch {
            return "\(error)"
        }
    }

    static func confirm(_ reason: String, timeout: TimeInterval = 90) throws {
        if let problem = availability() {
            throw VaultError.message("Windows Hello is unavailable: \(problem)")
        }
        let owner = parentWindow ?? GetConsoleWindow() ?? GetForegroundWindow()
        let result = try UserConsent.verify("Passhand wants to \(reason).", window: owner, timeout: timeout)
        guard result == 0 else { throw VaultError.authFailed } // 0 = Verified
    }
}

/// Windows.Security.Credentials.UI.UserConsentVerifier, called through raw WinRT/COM: Swift's WinSDK
/// module has no WinRT projection. Interface ids and vtable slots come from the Windows SDK headers;
/// IAsyncOperation ids are the parameterized ids for these enum results.
private enum UserConsent {
    typealias HSTRING = OpaquePointer
    typealias Object = UnsafeMutableRawPointer

    static let className = "Windows.Security.Credentials.UI.UserConsentVerifier"
    static let statics = guid("af4f3f91-564c-4ddc-b8b5-973447627c65")              // IUserConsentVerifierStatics
    static let interop = guid("39e050c3-4e74-441a-8dc0-b81104df949c")              // IUserConsentVerifierInterop (Windows 11)
    static let verificationOperation = guid("fd596ffd-2318-558f-9dbe-d21df43764a5") // IAsyncOperation<UserConsentVerificationResult>
    static let asyncInfo = guid("00000036-0000-0000-c000-000000000046")             // IAsyncInfo

    /// UserConsentVerifierAvailability: 0 Available, 1 DeviceNotPresent, 2 NotConfiguredForUser, 3 DisabledByPolicy, 4 DeviceBusy.
    static func availability() throws -> Int32 {
        let factory = try activationFactory(statics)
        defer { release(factory) }
        var operation: Object?
        typealias CheckAvailabilityAsync = @convention(c) (Object, UnsafeMutablePointer<Object?>) -> HRESULT
        try check(method(factory, 6, CheckAvailabilityAsync.self)(factory, &operation), "CheckAvailabilityAsync")
        guard let operation else { throw VaultError.message("Windows Hello returned nothing.") }
        defer { release(operation) }
        return try result(of: operation, timeout: 15)
    }

    /// UserConsentVerificationResult: 0 Verified, 1 DeviceNotPresent, 2 NotConfiguredForUser,
    /// 3 DisabledByPolicy, 4 DeviceBusy, 5 RetriesExhausted, 6 Canceled.
    static func verify(_ message: String, window: HWND?, timeout: TimeInterval) throws -> Int32 {
        let operation = try withHString(message) { text -> Object in
            // Windows 11 can tie the prompt to a window; otherwise use the plain call Windows 10 has.
            if let window, let factory = try? activationFactory(interop) {
                defer { release(factory) }
                typealias RequestVerificationForWindowAsync =
                    @convention(c) (Object, HWND?, HSTRING?, UnsafePointer<GUID>, UnsafeMutablePointer<Object?>) -> HRESULT
                var operation: Object?
                let hr = withUnsafePointer(to: verificationOperation) {
                    method(factory, 6, RequestVerificationForWindowAsync.self)(factory, window, text, $0, &operation)
                }
                if hr >= 0, let operation { return operation }
                Log.write("Windows Hello prompt for a window failed (HRESULT \(hex(hr))); using the plain prompt")
            }
            let factory = try activationFactory(statics)
            defer { release(factory) }
            typealias RequestVerificationAsync = @convention(c) (Object, HSTRING?, UnsafeMutablePointer<Object?>) -> HRESULT
            var operation: Object?
            try check(method(factory, 7, RequestVerificationAsync.self)(factory, text, &operation), "RequestVerificationAsync")
            guard let operation else { throw VaultError.message("Windows Hello returned nothing.") }
            return operation
        }
        defer { release(operation) }
        return try result(of: operation, timeout: timeout)
    }

    /// Waits for an IAsyncOperation of an enum and returns its result. Polls IAsyncInfo, so no
    /// completion handler (a COM object of our own) is needed.
    private static func result(of operation: Object, timeout: TimeInterval) throws -> Int32 {
        var info: Object?
        typealias QueryInterface = @convention(c) (Object, UnsafePointer<GUID>, UnsafeMutablePointer<Object?>) -> HRESULT
        try check(withUnsafePointer(to: asyncInfo) { method(operation, 0, QueryInterface.self)(operation, $0, &info) }, "IAsyncInfo")
        guard let info else { throw VaultError.message("Windows Hello returned nothing.") }
        defer { release(info) }

        typealias GetInt32 = @convention(c) (Object, UnsafeMutablePointer<Int32>) -> HRESULT
        typealias Cancel = @convention(c) (Object) -> HRESULT
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0 // AsyncStatus: 0 Started, 1 Completed, 2 Canceled, 3 Error
        while true {
            try check(method(info, 7, GetInt32.self)(info, &status), "IAsyncInfo.Status")
            if status != 0 { break }
            if Date() > deadline {
                // Don't let an unanswered prompt fill something minutes later.
                _ = method(info, 9, Cancel.self)(info)
                throw VaultError.authFailed
            }
            Sleep(100)
        }
        switch status {
        case 1:
            var value: Int32 = -1
            try check(method(operation, 8, GetInt32.self)(operation, &value), "GetResults")
            return value
        case 2:
            throw VaultError.authFailed
        default:
            var code: Int32 = 0
            _ = method(info, 8, GetInt32.self)(info, &code)
            throw VaultError.message("Windows Hello failed (HRESULT \(hex(code))).")
        }
    }

    // MARK: WinRT plumbing

    private static func activationFactory(_ iid: GUID) throws -> Object {
        guard let initialize = runtime.initialize, let getFactory = runtime.getActivationFactory else {
            throw VaultError.message("The Windows Runtime isn't available on this system.")
        }
        _ = initialize(1) // RO_INIT_MULTITHREADED; fine if this thread is already initialized
        return try withHString(className) { name in
            var factory: Object?
            try check(withUnsafePointer(to: iid) { getFactory(name, $0, &factory) }, "RoGetActivationFactory")
            guard let factory else { throw VaultError.message("Windows Hello returned nothing.") }
            return factory
        }
    }

    private static func withHString<T>(_ text: String, _ body: (HSTRING?) throws -> T) throws -> T {
        guard let create = runtime.createString, let delete = runtime.deleteString else {
            throw VaultError.message("The Windows Runtime isn't available on this system.")
        }
        let units = Array(text.utf16)
        var string: HSTRING?
        try check(units.withUnsafeBufferPointer { create($0.baseAddress, UInt32($0.count), &string) }, "WindowsCreateString")
        defer { _ = delete(string) }
        return try body(string)
    }

    /// Function `slot` of a COM object's vtable. Slots 0–2 are IUnknown, 3–5 IInspectable.
    private static func method<F>(_ object: Object, _ slot: Int, _ type: F.Type) -> F {
        let vtable = object.load(as: UnsafePointer<UnsafeRawPointer>.self)
        return unsafeBitCast(vtable[slot], to: type)
    }

    private static func release(_ object: Object) {
        typealias Release = @convention(c) (Object) -> UInt32
        _ = method(object, 2, Release.self)(object)
    }

    private static func check(_ hr: HRESULT, _ what: String) throws {
        guard hr >= 0 else { throw VaultError.message("Windows Hello: \(what) failed (HRESULT \(hex(hr))).") }
    }

    private static func hex(_ hr: Int32) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16) }

    private static func guid(_ text: String) -> GUID {
        let hex = text.replacingOccurrences(of: "-", with: "")
        let bytes = stride(from: 0, to: 32, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
        func number<T: FixedWidthInteger>(_ range: Range<Int>) -> T { bytes[range].reduce(0) { $0 << 8 | T($1) } }
        return GUID(Data1: number(0..<4), Data2: number(4..<6), Data3: number(6..<8),
                    Data4: (bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// roapi.h and winstring.h functions, loaded from combase.dll.
    private static let runtime = Runtime()

    private struct Runtime {
        var initialize: (@convention(c) (Int32) -> HRESULT)?
        var getActivationFactory: (@convention(c) (HSTRING?, UnsafePointer<GUID>, UnsafeMutablePointer<Object?>) -> HRESULT)?
        var createString: (@convention(c) (UnsafePointer<UInt16>?, UInt32, UnsafeMutablePointer<HSTRING?>) -> HRESULT)?
        var deleteString: (@convention(c) (HSTRING?) -> HRESULT)?

        init() {
            guard let module = "combase.dll".withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else { return }
            func load<F>(_ name: String, _ type: F.Type) -> F? {
                guard let address = GetProcAddress(module, name) else { return nil }
                return unsafeBitCast(address, to: type)
            }
            initialize = load("RoInitialize", (@convention(c) (Int32) -> HRESULT).self)
            getActivationFactory = load("RoGetActivationFactory", (@convention(c) (HSTRING?, UnsafePointer<GUID>, UnsafeMutablePointer<Object?>) -> HRESULT).self)
            createString = load("WindowsCreateString", (@convention(c) (UnsafePointer<UInt16>?, UInt32, UnsafeMutablePointer<HSTRING?>) -> HRESULT).self)
            deleteString = load("WindowsDeleteString", (@convention(c) (HSTRING?) -> HRESULT).self)
        }
    }
}
#endif
