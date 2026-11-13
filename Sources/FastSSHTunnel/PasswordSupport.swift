import Darwin
import Foundation
import Security

struct PasswordIdentity: Hashable, Sendable {
    let keychainID: UUID
    let account: String

    init(_ profile: TunnelProfile) {
        keychainID = profile.keychainID
        account = "\(profile.username)@\(profile.host):\(profile.sshPort)"
    }
}

struct TunnelCredential: Equatable, Sendable {
    let identity: PasswordIdentity
    var password: String
    var remember: Bool
}

enum PasswordKeychain {
    static func read(_ identity: PasswordIdentity) throws -> String? {
        var query = baseQuery(identity.keychainID)
        query[kSecAttrAccount as String] = identity.account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return password
    }

    static func write(_ password: String, for identity: PasswordIdentity) throws {
        let query = baseQuery(identity.keychainID)
        let attributes: [String: Any] = [
            kSecAttrAccount as String: identity.account,
            kSecAttrLabel as String: "FastSSHTunnel: \(identity.account)",
            kSecValueData as String: Data(password.utf8)
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove(_ keychainID: UUID) throws {
        let status = SecItemDelete(baseQuery(keychainID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func baseQuery(_ keychainID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.tunneldesk.ssh-password.\(keychainID.uuidString)"
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

struct SSHHostKeyPrompt: Sendable {
    static let prefix = "The authenticity of host '"

    let host: String
    let fingerprint: String

    init?(_ prompt: String) {
        let fingerprintLabel = " key fingerprint is: "
        let lines = prompt.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix(Self.prefix),
              let hostEnd = first.range(of: "' can't be established"),
              lines.last?.trimmingCharacters(in: .whitespaces) == "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
              let fingerprintLine = lines.dropFirst().first(where: { $0.contains(fingerprintLabel) }),
              let fingerprintStart = fingerprintLine.range(of: fingerprintLabel) else { return nil }

        let hostStart = first.index(first.startIndex, offsetBy: Self.prefix.count)
        guard hostStart < hostEnd.lowerBound else { return nil }
        let host = first[hostStart..<hostEnd.lowerBound]
        let fingerprint = fingerprintLine[fingerprintStart.upperBound...]
        guard !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fingerprint.hasPrefix("SHA256:"), fingerprint.utf8.count == 50,
              Data(base64Encoded: String(fingerprint.dropFirst("SHA256:".count)) + "=")?.count == 32 else { return nil }
        self.host = String(host)
        self.fingerprint = String(fingerprint)
    }
}

/// Supplies SSH_ASKPASS responses over a protected local socket. The password
/// never appears in the helper script, command arguments, environment, or files.
final class SSHAskpassBroker: @unchecked Sendable {
    let directory: URL
    let helperURL: URL
    let environment: [String: String]
    private let password: Data?
    private let confirmHostKey: @MainActor @Sendable (SSHHostKeyPrompt) -> Bool
    private let token = UUID().uuidString
    private let source: DispatchSourceRead
    private let lock = NSCondition()
    private var stopped = false
    private var sshProcessID: Int32?

    init(password: String, confirmHostKey: @escaping @MainActor @Sendable (SSHHostKeyPrompt) -> Bool = { _ in false }) throws {
        // Keep the Unix socket path below sockaddr_un's 104-byte limit.
        directory = URL(fileURLWithPath: "/private/tmp/fastssh-\(UUID().uuidString)", isDirectory: true)
        helperURL = directory.appendingPathComponent("askpass")
        let socketURL = directory.appendingPathComponent("socket")
        self.password = password.isEmpty ? nil : Data((password + "\n").utf8)
        self.confirmHostKey = confirmHostKey
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketURL.path.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(descriptor, 4) == 0,
                  Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let script = """
            #!/bin/sh
            [ "${SSH_ASKPASS_PROMPT-}" != none ] || exit 1
            response=$(printf '%s %s\\n%s\\000' "$FASTSSH_ASKPASS_TOKEN" "$PPID" "$1" | /usr/bin/nc -U "$FASTSSH_ASKPASS_SOCKET") || exit 1
            [ -n "$response" ] || exit 1
            printf '%s\\n' "$response"
            """
            try Data(script.utf8).write(to: helperURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment = [
            "SSH_ASKPASS": helperURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "SSH_ASKPASS_PROMPT": "",
            "FASTSSH_ASKPASS_SOCKET": socketURL.path,
            "FASTSSH_ASKPASS_TOKEN": token
        ]
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "FastSSHTunnel.askpass"))
        source.setEventHandler { [weak self] in self?.respond(on: descriptor) }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    func authorize(processID: Int32) {
        lock.lock()
        sshProcessID = processID
        lock.broadcast()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.broadcast()
        lock.unlock()
        guard shouldStop else { return }
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    private func respond(on listener: Int32) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        var closeClient = true
        defer { if closeClient { Darwin.close(client) } }
        // Accepted sockets must use blocking reads with the bounded timeout below.
        guard Darwin.fcntl(client, F_SETFL, 0) == 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard let request = readRequest(from: client), let headerEnd = request.firstIndex(of: "\n") else { return }
        let header = request[..<headerEnd].split(separator: " ")
        guard header.count == 2, header[0] == token, let parentID = Int32(header[1]),
              isAuthorized(parentID, waitForLaunch: true) else { return }
        let prompt = String(request[request.index(after: headerEnd)...])
        if prompt.hasPrefix(SSHHostKeyPrompt.prefix) {
            guard let key = SSHHostKeyPrompt(prompt) else { return }
            closeClient = false
            Task { @MainActor [weak self] in
                defer { Darwin.close(client) }
                guard let self, self.isAuthorized(parentID) else { return }
                let answer = self.confirmHostKey(key) ? key.fingerprint : "no"
                guard self.isAuthorized(parentID) else { return }
                Self.send(Data((answer + "\n").utf8), to: client)
            }
        } else if let password, prompt.range(of: "password:", options: .caseInsensitive) != nil {
            Self.send(password, to: client)
        }
    }

    private func readRequest(from client: Int32) -> String? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.count < 16_384 {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return nil }
            let received = buffer.prefix(count)
            if let end = received.firstIndex(of: 0) {
                request.append(contentsOf: received[..<end])
                return String(data: request, encoding: .utf8)
            }
            request.append(contentsOf: received)
        }
        return nil
    }

    private func isAuthorized(_ parentID: Int32, waitForLaunch: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if waitForLaunch {
            let deadline = Date(timeIntervalSinceNow: 2)
            while sshProcessID == nil && !stopped {
                if !lock.wait(until: deadline) { break }
            }
        }
        return !stopped && sshProcessID == parentID
    }

    private static func send(_ response: Data, to client: Int32) {
        response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(client, base.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
