import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct FastSSHTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @MainActor private var store: TunnelStore { appDelegate.tunnelStore }

    var body: some Scene {
        Window("FastSSHTunnel", id: AppDelegate.mainWindowID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(appDelegate)
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FastSSHTunnel") {
                    appDelegate.showAboutPanel()
                }
            }
            CommandMenu("Diagnostics") {
                Button("Export Debug Logs…") { appDelegate.exportDebugLogs() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Tunnel") {
                    store.addProfile()
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show FastSSHTunnel") {
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static let mainWindowID = "main"
    private(set) lazy var tunnelStore = TunnelStore()
    var openMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the UI must not tear down the shared tunnel store or its SSH processes.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnelStore.disconnectAllForQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Until SwiftUI installs the window action, let it handle the initial launch.
        guard openMainWindow != nil else { return true }
        showMainWindow()
        return false
    }

    func showMainWindow() {
        // A single Window scene reuses an existing window and recreates a closed one.
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func exportDebugLogs() {
        let panel = NSSavePanel()
        panel.title = "Export Debug Logs"
        panel.prompt = "Export"
        panel.message = "The log includes app and macOS versions, timestamps, tunnel identifiers, and diagnostic events. Passwords, connection settings, and raw SSH output are omitted."
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "FastSSHTunnel Debug Log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DebugLog.shared.contents().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could Not Export Debug Logs"
            alert.runModal()
        }
    }

    func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Developped by Hugo Remillard\nRelease date: November 5, 2026",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "FastSSHTunnel",
            .credits: credits
        ]
        if let icon = aboutIcon {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var aboutIcon: NSImage? {
        // Load the source PNG explicitly: NSApplication's icon image can be a
        // generic placeholder before Launch Services refreshes the app bundle.
        if let url = Bundle.main.url(forResource: "SSHLightningPipeMinimalIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSApp.applicationIconImage
    }
}

struct TunnelProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String = "New tunnel"
    var host: String = ""
    var username: String = ""
    var sshPort: Int = 22
    var socksPort: Int = 1080
    var identityFile: String = ""
    var startPage: String = "https://example.com"
    // Optional so profiles saved before device SSH was added still decode.
    var sshDevice: SSHDevice?
    var remoteDesktop: RemoteDesktop?
    var staticPort: StaticPortForward?
    // Restores stage fresh Keychain items while keeping profile IDs stable.
    var passwordStorageID: UUID?

    var keychainID: UUID { passwordStorageID ?? id }
    var enabledRemoteDesktop: RemoteDesktop? {
        guard let remoteDesktop, remoteDesktop.isEnabled else { return nil }
        return remoteDesktop
    }

    var enabledStaticPort: StaticPortForward? {
        guard let staticPort, staticPort.isEnabled else { return nil }
        return staticPort
    }

    var localPorts: [Int] {
        [socksPort] + [enabledRemoteDesktop?.localPort, enabledStaticPort?.localPort].compactMap { $0 }
    }

    var portableSettings: TunnelProfile {
        var copy = self
        copy.passwordStorageID = nil
        return copy
    }

    func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(portableSettings).write(to: url, options: .atomic)
    }
}

private enum TunnelProfileImportError: LocalizedError {
    case invalidFile
    case noAvailableLocalPort
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a JSON profile exported by FastSSHTunnel."
        case .noAvailableLocalPort: "No local port is available. Free a port and try again."
        case .saveFailed: "The imported profile could not be saved."
        }
    }
}

enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile]
    @Published var states: [UUID: TunnelState] = [:]
    @Published var notices: [UUID: String] = [:]
    @Published var missingAuthenticationProfileID: UUID?
    @Published private var credentials: [UUID: TunnelCredential] = [:]
    @Published private(set) var credentialErrors: [UUID: String] = [:]
    @Published private(set) var loadingCredentials: Set<PasswordIdentity> = []
    @Published private(set) var trafficStatistics: [UUID: TunnelTrafficStatistics] = [:]
    @Published private(set) var trafficErrors: [UUID: String] = [:]
    @Published private(set) var isTransferringBackup = false

    // Keep the original persistence key so renaming the app retains saved connections.
    private let storageKey = "TunnelDesk.profiles.v1"
    private let retiredKeychainIDsKey = "TunnelDesk.retiredKeychainIDs"
    private var processes: [UUID: Process] = [:]
    private var activeProfiles: [UUID: TunnelProfile] = [:]
    private var outputHandles: [UUID: [Any]] = [:]
    private var askpassBrokers: [UUID: SSHAskpassBroker] = [:]
    private var outputBuffers: [UUID: String] = [:]
    private var trafficMonitors: [UUID: TunnelTrafficMonitor] = [:]
    private var isPreview = false
    private var isQuitting = false
    private var savingCredentials = 0

    init() {
        let saved = UserDefaults.standard.data(forKey: storageKey)
        profiles = (try? saved.flatMap { try JSONDecoder().decode([TunnelProfile].self, from: $0) }) ?? []
        removeRetiredCredentials()
        DebugLog.shared.record(.started)
    }

    init(previewProfiles: [TunnelProfile]) {
        profiles = previewProfiles
        isPreview = true
    }

    func addProfile() {
        guard !isTransferringBackup else { return }
        let usedPorts = reservedLocalPorts()
        let openPort = (1080...65535).first { !usedPorts.contains($0) } ?? 1080
        var profile = TunnelProfile()
        profile.name = "Tunnel \(profiles.count + 1)"
        profile.socksPort = openPort
        profiles.append(profile)
        save(profiles)
    }

    func importProfile(from url: URL) throws {
        guard !isTransferringBackup else { throw BackupError.busy }
        let data = try Data(contentsOf: url)
        guard var profile = try? JSONDecoder().decode(TunnelProfile.self, from: data) else {
            throw TunnelProfileImportError.invalidFile
        }

        // A new ID keeps this copy separate from local credentials and Firefox data.
        profile.id = UUID()
        profile.passwordStorageID = nil
        var usedPorts = reservedLocalPorts()
        var portChanges: [String] = []
        if usedPorts.contains(profile.socksPort) {
            let otherPorts = Set([profile.enabledRemoteDesktop?.localPort, profile.enabledStaticPort?.localPort].compactMap { $0 })
            guard let openPort = (1080...65535).first(where: { !usedPorts.contains($0) && !otherPorts.contains($0) }) else {
                throw TunnelProfileImportError.noAvailableLocalPort
            }
            portChanges.append("SOCKS port \(openPort) (was \(profile.socksPort))")
            profile.socksPort = openPort
        }
        usedPorts.insert(profile.socksPort)
        if var remoteDesktop = profile.enabledRemoteDesktop, usedPorts.contains(remoteDesktop.localPort) {
            let preferredPorts = RemoteDesktop.defaultLocalPort...65535
            guard let openPort = preferredPorts.first(where: { !usedPorts.contains($0) && $0 != profile.enabledStaticPort?.localPort }) else {
                throw TunnelProfileImportError.noAvailableLocalPort
            }
            portChanges.append("local Remote Desktop port \(openPort) (was \(remoteDesktop.localPort))")
            remoteDesktop.localPort = openPort
            profile.remoteDesktop = remoteDesktop
        }
        if let remoteDesktop = profile.enabledRemoteDesktop { usedPorts.insert(remoteDesktop.localPort) }
        if var staticPort = profile.enabledStaticPort, usedPorts.contains(staticPort.localPort) {
            guard let openPort = (1024...65535).first(where: { !usedPorts.contains($0) }) else {
                throw TunnelProfileImportError.noAvailableLocalPort
            }
            portChanges.append("local static port \(openPort) (was \(staticPort.localPort))")
            staticPort.localPort = openPort
            profile.staticPort = staticPort
        }

        let updatedProfiles = profiles + [profile]
        guard save(updatedProfiles) else { throw TunnelProfileImportError.saveFailed }
        profiles = updatedProfiles
        if !portChanges.isEmpty {
            notices[profile.id] = "Imported with \(portChanges.joined(separator: " and ")) to avoid a port conflict."
        } else {
            notices[profile.id] = "Tunnel profile imported."
        }
    }

    func createBackup(at url: URL, passphrase: String) async throws {
        try beginBackupTransfer()
        defer { isTransferringBackup = false }

        let snapshot = profiles
        let isPreview = isPreview
        try await Task.detached {
            let entries = try snapshot.map { profile in
                let password = isPreview ? nil : try PasswordKeychain.read(PasswordIdentity(profile))
                return TunnelBackup.Entry(profile: profile.portableSettings, password: password)
            }
            try TunnelBackup(entries: entries).write(to: url, passphrase: passphrase)
        }.value
    }

    func restore(_ backup: TunnelBackup) async throws {
        try beginBackupTransfer()
        defer { isTransferringBackup = false }

        let entries = backup.entries.map { entry in
            var profile = entry.profile
            profile.passwordStorageID = UUID()
            return TunnelBackup.Entry(profile: profile, password: entry.password)
        }
        let restoredProfiles = entries.map(\.profile)
        let saved = try JSONEncoder().encode(restoredProfiles)
        if !isPreview {
            // Keep the current credentials usable until the new profiles have been saved.
            // At next launch, remove only items that the persisted profiles do not use.
            let candidates = profiles.map(\.keychainID) + entries.filter { $0.password != nil }.map(\.profile.keychainID)
            let pending = UserDefaults.standard.stringArray(forKey: retiredKeychainIDsKey) ?? []
            let keychainIDs = Set(pending + candidates.map(\.uuidString))
            UserDefaults.standard.set(Array(keychainIDs), forKey: retiredKeychainIDsKey)
            try await Task.detached {
                var written: [UUID] = []
                do {
                    for entry in entries {
                        guard let password = entry.password else { continue }
                        let identity = PasswordIdentity(entry.profile)
                        try PasswordKeychain.write(password, for: identity)
                        written.append(identity.keychainID)
                    }
                } catch {
                    for id in written { try? PasswordKeychain.remove(id) }
                    throw error
                }
            }.value
            UserDefaults.standard.set(saved, forKey: storageKey)
        }

        for profile in profiles where processes[profile.id] != nil { disconnect(profile) }
        states = [:]
        notices = [:]
        credentials = [:]
        credentialErrors = [:]
        profiles = restoredProfiles
    }

    private func beginBackupTransfer() throws {
        guard !isTransferringBackup, savingCredentials == 0 else { throw BackupError.busy }
        isTransferringBackup = true
    }

    private func removeRetiredCredentials() {
        guard let pending = UserDefaults.standard.stringArray(forKey: retiredKeychainIDsKey) else { return }
        let liveIDs = Set(profiles.map(\.keychainID))
        let retry = pending.compactMap(UUID.init(uuidString:)).filter { id in
            guard !liveIDs.contains(id) else { return false }
            do {
                try PasswordKeychain.remove(id)
                return false
            } catch {
                return true
            }
        }
        UserDefaults.standard.set(retry.map(\.uuidString), forKey: retiredKeychainIDsKey)
    }

    @discardableResult
    func update(_ profile: TunnelProfile) -> Bool {
        guard !isTransferringBackup,
              let index = profiles.firstIndex(where: { $0.id == profile.id && $0.keychainID == profile.keychainID }) else { return false }
        profiles[index] = profile
        return save(profiles)
    }

    func delete(_ profile: TunnelProfile) {
        guard !isTransferringBackup else { return }
        if isPreview {
            profiles.removeAll { $0.id == profile.id }
            credentials[profile.id] = nil
            notices[profile.id] = nil
            return
        }
        do {
            try PasswordKeychain.remove(profile.keychainID)
        } catch {
            notices[profile.id] = "Could not remove the saved password: \(error.localizedDescription)"
            return
        }
        disconnect(profile)
        profiles.removeAll { $0.id == profile.id }
        states[profile.id] = nil
        notices[profile.id] = nil
        credentials[profile.id] = nil
        credentialErrors[profile.id] = nil
        removeFirefoxProfile(for: profile)
        save(profiles)
    }

    func state(for profile: TunnelProfile) -> TunnelState {
        states[profile.id] ?? .disconnected
    }

    func displayedSOCKSPort(for profile: TunnelProfile) -> Int {
        activeProfiles[profile.id]?.socksPort ?? profile.socksPort
    }

    func activeStaticPort(for profile: TunnelProfile) -> StaticPortForward? {
        activeProfiles[profile.id]?.enabledStaticPort
    }

    func activeRemoteDesktop(for profile: TunnelProfile) -> RemoteDesktop? {
        activeProfiles[profile.id]?.enabledRemoteDesktop
    }

    func credential(for profile: TunnelProfile) -> TunnelCredential {
        let identity = PasswordIdentity(profile)
        if let credential = credentials[profile.id], credential.identity == identity { return credential }
        return TunnelCredential(identity: identity, password: "", remember: false)
    }

    func setPassword(_ password: String, for profile: TunnelProfile) {
        var credential = credential(for: profile)
        credential.password = password
        credentials[profile.id] = credential
        credentialErrors[profile.id] = nil
    }

    func setRememberPassword(_ remember: Bool, for profile: TunnelProfile) {
        var credential = credential(for: profile)
        credential.remember = remember
        credentials[profile.id] = credential
    }

    func loadCredential(for profile: TunnelProfile) async {
        let identity = PasswordIdentity(profile)
        guard credentials[profile.id]?.identity != identity else { return }
        if isPreview {
            credentials[profile.id] = TunnelCredential(identity: identity, password: "", remember: false)
            return
        }
        loadingCredentials.insert(identity)
        defer { loadingCredentials.remove(identity) }
        let result = await Task.detached { Result { try PasswordKeychain.read(identity) } }.value
        guard !Task.isCancelled,
              profiles.contains(where: { PasswordIdentity($0) == identity }),
              credentials[profile.id]?.identity != identity else { return }
        switch result {
        case .success(let password):
            credentials[profile.id] = TunnelCredential(identity: identity, password: password ?? "", remember: password != nil)
            credentialErrors[profile.id] = nil
        case .failure(let error):
            credentialErrors[profile.id] = "Could not read Keychain: \(error.localizedDescription)"
        }
    }

    func saveCredential(_ credential: TunnelCredential) async throws {
        guard !isPreview else { return }
        guard !isTransferringBackup,
              profiles.contains(where: { $0.keychainID == credential.identity.keychainID }) else { throw BackupError.busy }
        savingCredentials += 1
        defer { savingCredentials -= 1 }
        try await Task.detached {
            if credential.remember && !credential.password.isEmpty {
                try PasswordKeychain.write(credential.password, for: credential.identity)
            } else {
                try PasswordKeychain.remove(credential.identity.keychainID)
            }
        }.value
    }

    func connect(_ profile: TunnelProfile) {
        guard !isQuitting else { return }
        guard !isPreview else {
            notices[profile.id] = "This is a design preview. Run the app to connect a tunnel."
            return
        }
        if processes[profile.id]?.isRunning == true { return }
        guard !loadingCredentials.contains(PasswordIdentity(profile)) else { return }

        guard SSHConfiguration.hasAuthentication(password: credential(for: profile).password, identityFile: profile.identityFile) else {
            let issue = "Enter an SSH password or select an SSH key to connect."
            DebugLog.shared.record(.validationFailed, profileID: profile.id)
            states[profile.id] = .failed(issue)
            notices[profile.id] = issue
            missingAuthenticationProfileID = profile.id
            return
        }

        guard let issue = validationIssue(for: profile) else {
            start(profile)
            return
        }
        DebugLog.shared.record(.validationFailed, profileID: profile.id)
        states[profile.id] = .failed(issue)
        notices[profile.id] = issue
    }

    func disconnect(_ profile: TunnelProfile) {
        disconnect(profileID: profile.id)
    }

    func disconnectAllForQuit() {
        isQuitting = true
        // Keep a snapshot so Quit also waits for tunnels already disconnecting.
        let ownedProcesses = processes
        for profileID in ownedProcesses.keys { disconnect(profileID: profileID) }
        for process in ownedProcesses.values { process.waitUntilExit() }
    }

    private func disconnect(profileID: UUID) {
        if !isPreview { DebugLog.shared.record(.disconnected, profileID: profileID) }
        stopTrafficMonitoring(for: profileID)
        activeProfiles[profileID] = nil
        outputHandles[profileID] = nil
        askpassBrokers.removeValue(forKey: profileID)?.stop()
        outputBuffers[profileID] = nil
        states[profileID] = .disconnected
        notices[profileID] = "Tunnel stopped."
        if let process = processes[profileID], process.isRunning { process.terminate() }
    }

    func openInFirefox(_ profile: TunnelProfile) {
        guard state(for: profile) == .connected else {
            notices[profile.id] = "Connect this tunnel before opening Firefox."
            return
        }
        launchFirefox(for: profile)
    }

    func openSSH(_ profile: TunnelProfile) async throws {
        guard state(for: profile) == .connected,
              processes[profile.id]?.isRunning == true,
              let socksPort = activeProfiles[profile.id]?.socksPort else {
            throw SSHDeviceError("Connect this tunnel before opening SSH.")
        }
        // Use the running tunnel's port even if its settings have since been edited.
        try await SSHDeviceTerminal.open(profile.sshDevice ?? SSHDevice(), socksPort: socksPort)
    }

    func openRemoteDesktop(_ profile: TunnelProfile) async throws {
        guard state(for: profile) == .connected, processes[profile.id]?.isRunning == true else {
            throw RemoteDesktopError("Connect the tunnel before opening Remote Desktop.")
        }
        guard let active = activeRemoteDesktop(for: profile), active == profile.enabledRemoteDesktop else {
            throw RemoteDesktopError("Reconnect the tunnel to apply the Remote Desktop settings.")
        }
        try await active.openClient()
    }

    func connectAndBrowse(_ profile: TunnelProfile) {
        switch state(for: profile) {
        case .connected:
            launchFirefox(for: profile)
        case .connecting:
            notices[profile.id] = "Waiting for the tunnel to finish connecting…"
            openFirefoxWhenConnected(profile)
        default:
            connect(profile)
            if state(for: profile) == .connecting {
                openFirefoxWhenConnected(profile)
            }
        }
    }

    @discardableResult
    private func save(_ profiles: [TunnelProfile]) -> Bool {
        guard !isPreview else { return true }
        guard let data = try? JSONEncoder().encode(profiles) else { return false }
        UserDefaults.standard.set(data, forKey: storageKey)
        return true
    }

    private func reservedLocalPorts(excluding id: UUID? = nil) -> Set<Int> {
        let savedPorts = profiles.filter { $0.id != id }.flatMap(\.localPorts)
        let activePorts = activeProfiles.values.filter { $0.id != id }.flatMap(\.localPorts)
        return Set(savedPorts).union(activePorts)
    }

    private func validationIssue(for profile: TunnelProfile) -> String? {
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an SSH host."
        }
        guard !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an SSH username."
        }
        guard (1...65535).contains(profile.sshPort) else { return "SSH port must be between 1 and 65535." }
        guard (1...65535).contains(profile.socksPort) else { return "SOCKS port must be between 1 and 65535." }
        let reservedPorts = reservedLocalPorts(excluding: profile.id)
        guard !reservedPorts.contains(profile.socksPort) else {
            return "SOCKS port \(profile.socksPort) is already assigned to another tunnel."
        }
        if let remoteDesktop = profile.enabledRemoteDesktop {
            if let issue = remoteDesktop.validationIssue { return issue }
            if remoteDesktop.localPort == profile.socksPort {
                return "Choose a different local port for Remote Desktop and SOCKS."
            }
            if reservedPorts.contains(remoteDesktop.localPort) {
                return "Local Remote Desktop port \(remoteDesktop.localPort) is already assigned to another tunnel."
            }
        }
        if let staticPort = profile.enabledStaticPort {
            if let issue = staticPort.validationIssue { return issue }
            if staticPort.localPort == profile.socksPort || staticPort.localPort == profile.enabledRemoteDesktop?.localPort {
                return "Choose a different local port for static forwarding, SOCKS, and Remote Desktop."
            }
            if reservedPorts.contains(staticPort.localPort) {
                return "Local static port \(staticPort.localPort) is already assigned to another tunnel."
            }
        }
        if !profile.identityFile.isEmpty && !FileManager.default.fileExists(atPath: profile.identityFile) {
            return "The selected identity file no longer exists."
        }
        if credential(for: profile).password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            return "The SSH password cannot contain line breaks or a null character."
        }
        return nil
    }

    private func start(_ profile: TunnelProfile) {
        stopTrafficMonitoring(for: profile.id)
        let process = Process()
        let pipe = Pipe()
        let password = credential(for: profile).password
        let readyMarker = "FASTSSH_READY_\(UUID().uuidString)"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = SSHConfiguration.arguments(for: profile, usesPassword: !password.isEmpty, readyMarker: readyMarker)
        do {
            let broker = try SSHAskpassBroker(password: password) { [weak self, weak process] key in
                guard let self, let process, self.processes[profile.id] === process, process.isRunning else { return false }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Trust this SSH server?"
                alert.informativeText = """
                OpenSSH has not seen this host key for \(key.host).

                Host key fingerprint
                \(key.fingerprint)

                Compare this fingerprint with one from your server administrator before trusting it. An impersonator could receive your SSH password if you trust the wrong key.
                """
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Trust and Connect")
                return alert.runModal() == .alertSecondButtonReturn
            }
            askpassBrokers[profile.id] = broker
            process.environment = ProcessInfo.processInfo.environment.merging(broker.environment) { _, new in new }
        } catch {
            DebugLog.shared.record(.sshPromptSetupFailed, profileID: profile.id)
            states[profile.id] = .failed(error.localizedDescription)
            notices[profile.id] = "Could not prepare SSH prompts: \(error.localizedDescription)"
            return
        }
        outputBuffers[profile.id] = ""
        states[profile.id] = .connecting
        DebugLog.shared.record(.connecting, profileID: profile.id)
        notices[profile.id] = "Starting SSH tunnel…"

        let outputHandler: @Sendable (FileHandle) -> Void = { [weak self, weak process] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let process else { return }
                self?.handleSSHOutput(text, profile: profile, process: process, readyMarker: readyMarker)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = outputHandler
        outputHandles[profile.id] = [pipe, outputHandler as Any]

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                guard let self else { return }
                // A profile can be stopped and immediately started again. Never let
                // the old process overwrite the state of a newer one.
                guard self.processes[profile.id] === finishedProcess else { return }
                DebugLog.shared.record(.sshExited(finishedProcess.terminationStatus), profileID: profile.id)
                self.stopTrafficMonitoring(for: profile.id)
                self.processes[profile.id] = nil
                let wasActive = self.activeProfiles.removeValue(forKey: profile.id) != nil
                self.outputHandles[profile.id] = nil
                self.askpassBrokers.removeValue(forKey: profile.id)?.stop()
                self.outputBuffers[profile.id] = nil
                if wasActive {
                    self.states[profile.id] = .failed("SSH exited with status \(finishedProcess.terminationStatus).")
                    if self.notices[profile.id] == "Starting SSH tunnel…" || self.notices[profile.id]?.hasPrefix("Tunnel connected at") == true {
                        self.notices[profile.id] = "SSH exited with status \(finishedProcess.terminationStatus)."
                    }
                }
            }
        }

        do {
            try process.run()
            askpassBrokers[profile.id]?.authorize(processID: process.processIdentifier)
            processes[profile.id] = process
            activeProfiles[profile.id] = profile
        } catch {
            askpassBrokers.removeValue(forKey: profile.id)?.stop()
            outputBuffers[profile.id] = nil
            DebugLog.shared.record(.sshLaunchFailed, profileID: profile.id)
            states[profile.id] = .failed(error.localizedDescription)
            notices[profile.id] = "Could not start SSH: \(error.localizedDescription)"
        }
    }

    private func handleSSHOutput(_ text: String, profile: TunnelProfile, process: Process, readyMarker: String) {
        guard processes[profile.id] === process, activeProfiles[profile.id] != nil else { return }
        let combined = (outputBuffers[profile.id] ?? "") + text
        var lines = combined.components(separatedBy: "\n")
        outputBuffers[profile.id] = String((lines.removeLast()).suffix(4096))
        for line in lines {
            let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if message == readyMarker && process.isRunning {
                DebugLog.shared.record(.connected, profileID: profile.id)
                states[profile.id] = .connected
                notices[profile.id] = "Tunnel connected at socks5://127.0.0.1:\(profile.socksPort)"
                askpassBrokers.removeValue(forKey: profile.id)?.stop()
                startTrafficMonitoring(for: profile, process: process)
            } else if !message.isEmpty {
                DebugLog.shared.record(.sshDiagnostic(.classify(message)), profileID: profile.id)
                notices[profile.id] = message
            }
        }
    }

    private func startTrafficMonitoring(for profile: TunnelProfile, process: Process) {
        guard trafficMonitors[profile.id] == nil else { return }
        do {
            trafficMonitors[profile.id] = try TunnelTrafficMonitor(
                processID: process.processIdentifier,
                socksPort: profile.socksPort,
                localForwardPort: profile.enabledRemoteDesktop?.localPort,
                staticForwardPort: profile.enabledStaticPort?.localPort,
                onSample: { [weak self, weak process] statistics in
                    Task { @MainActor in
                        guard let self, let process,
                              self.processes[profile.id] === process,
                              self.state(for: profile) == .connected else { return }
                        self.trafficStatistics[profile.id] = statistics
                        self.trafficErrors[profile.id] = nil
                    }
                },
                onFailure: { [weak self, weak process] message in
                    Task { @MainActor in
                        guard let self, let process,
                              self.processes[profile.id] === process,
                              self.state(for: profile) == .connected else { return }
                        DebugLog.shared.record(.trafficFailed, profileID: profile.id)
                        self.trafficErrors[profile.id] = message
                    }
                }
            )
        } catch {
            DebugLog.shared.record(.trafficFailed, profileID: profile.id)
            trafficErrors[profile.id] = "Could not start live traffic statistics: \(error.localizedDescription)"
        }
    }

    private func stopTrafficMonitoring(for id: UUID) {
        trafficMonitors.removeValue(forKey: id)?.stop()
        trafficStatistics[id] = nil
        trafficErrors[id] = nil
    }

    private func openFirefoxWhenConnected(_ profile: TunnelProfile, remainingChecks: Int = 90) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.profiles.contains(where: { $0.keychainID == profile.keychainID }) else { return }
            switch self.state(for: profile) {
            case .connected:
                self.launchFirefox(for: profile)
            case .connecting where remainingChecks > 0:
                self.openFirefoxWhenConnected(profile, remainingChecks: remainingChecks - 1)
            case .connecting:
                self.notices[profile.id] = "The tunnel is taking too long to connect."
            case .failed(let message):
                self.notices[profile.id] = "Firefox was not opened: \(message)"
            case .disconnected:
                self.notices[profile.id] = "Firefox was not opened because the tunnel stopped."
            }
        }
    }

    private func launchFirefox(for profile: TunnelProfile) {
        guard state(for: profile) == .connected,
              processes[profile.id]?.isRunning == true,
              let socksPort = activeProfiles[profile.id]?.socksPort else {
            notices[profile.id] = "Connect this tunnel before opening Firefox."
            return
        }
        guard let firefox = firefoxExecutable() else {
            DebugLog.shared.record(.firefoxNotFound, profileID: profile.id)
            notices[profile.id] = "Firefox was not found in /Applications. Install Firefox, then try again."
            return
        }
        let firefoxProfile = firefoxProfileURL(for: profile)
        do {
            try FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
            let preferences = firefoxPreferences(socksPort: socksPort)
            try preferences.write(to: firefoxProfile.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)

            let browser = Process()
            browser.executableURL = firefox
            browser.arguments = ["-no-remote", "-profile", firefoxProfile.path, "-new-window", normalizedURL(profile.startPage)]
            try browser.run()
            DebugLog.shared.record(.firefoxOpened, profileID: profile.id)
            notices[profile.id] = "Opening Firefox with SOCKS5 proxy 127.0.0.1:\(socksPort)."
        } catch {
            DebugLog.shared.record(.firefoxFailed, profileID: profile.id)
            notices[profile.id] = "Could not open Firefox: \(error.localizedDescription)"
        }
    }

    private func firefoxExecutable() -> URL? {
        let candidates = [
            "/Applications/Firefox.app/Contents/MacOS/firefox",
            "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func firefoxProfileURL(for profile: TunnelProfile) -> URL {
        // Retain the original folder to reuse existing Firefox sessions and profiles.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TunnelDesk", isDirectory: true)
            .appendingPathComponent("FirefoxProfiles", isDirectory: true)
        return base.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    private func removeFirefoxProfile(for profile: TunnelProfile) {
        let directory = firefoxProfileURL(for: profile)
        try? FileManager.default.removeItem(at: directory)
    }

    private func firefoxPreferences(socksPort: Int) -> String {
        let socksHost = "127.0.0.1"
        return """
        // Managed by FastSSHTunnel. This profile is separate from your normal Firefox profile.
        user_pref(\"network.proxy.type\", 1);
        user_pref(\"network.proxy.socks\", \"\(socksHost)\");
        user_pref(\"network.proxy.socks_port\", \(socksPort));
        user_pref(\"network.proxy.socks_version\", 5);
        user_pref(\"network.proxy.socks_remote_dns\", true);
        user_pref(\"media.peerconnection.ice.proxy_only\", true);
        user_pref(\"network.proxy.no_proxies_on\", \"\");
        user_pref(\"browser.startup.homepage\", \"about:blank\");
        """
    }

    private func normalizedURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "about:blank" }
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var store: TunnelStore
    @EnvironmentObject private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var publicIPAddress: PublicIPAddressStore
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var isOpeningBackup = false

    init(publicIPAddress: PublicIPAddressStore? = nil) {
        _publicIPAddress = StateObject(wrappedValue: publicIPAddress ?? PublicIPAddressStore())
    }

    var body: some View {
        VStack(spacing: 0) {
            PublicIPAddressBar(
                address: publicIPAddress.address,
                isRefreshing: publicIPAddress.isRefreshing,
                errorMessage: publicIPAddress.errorMessage,
                lastUpdated: publicIPAddress.lastUpdated,
                refresh: { Task { await publicIPAddress.refresh() } }
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            GeometryReader { available in
              NavigationSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("Tunnels").font(.headline)
                        Spacer()
                        Button(action: addTunnel) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Add connection")
                        .accessibilityLabel("Add connection")
                        Button(role: .destructive, action: deleteSelectedTunnel) {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedProfile == nil)
                        .help("Delete selected tunnel")
                        .accessibilityLabel("Delete selected tunnel")
                        Menu {
                            Button("Import Profile…", action: importTunnel)
                            if let profile = selectedProfile?.wrappedValue {
                                Button("Export \(profile.name.isEmpty ? "Untitled tunnel" : profile.name)…", action: exportSelectedTunnel)
                            } else {
                                Button("Export Selected Tunnel…", action: exportSelectedTunnel)
                                    .disabled(true)
                            }
                            Divider()
                            Button("Back Up All Tunnels…", action: backupTunnels)
                                .disabled(isOpeningBackup)
                            Button("Restore Backup…", action: restoreTunnels)
                                .disabled(isOpeningBackup)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuIndicator(.hidden)
                        .controlSize(.small)
                        .help("Import, export, back up, or restore tunnel profiles")
                        .accessibilityLabel("Tunnel profile actions")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    TextField("Search tunnels", text: $searchText, prompt: Text("Search tunnels…"))
                        .modifier(EditableFieldStyle())
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)

                    Text("Select a tunnel below to view or export it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)

                    Divider()

                    List(selection: $selection) {
                        ForEach(filteredProfiles) { profile in
                            TunnelRow(profile: profile, state: store.state(for: profile), isSelected: selection == profile.id)
                                .tag(profile.id)
                        }
                    }
                    .overlay {
                        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredProfiles.isEmpty {
                            Text("No matching tunnels")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                if let profile = selectedProfile {
                    TunnelDetailView(profile: profile)
                        .id(profile.wrappedValue.id)
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    EmptyStateView(addTunnel: addTunnel)
                }
            }
              .disabled(store.isTransferringBackup)
              .frame(width: available.size.width, height: available.size.height, alignment: .topLeading)
              .clipped()
            }
        }
        .task { await publicIPAddress.refreshContinuously() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await publicIPAddress.refresh() }
            }
        }
        .onAppear {
            // Keep this action in the app delegate so Dock reopen still works after
            // SwiftUI destroys the closed window's view hierarchy.
            appDelegate.openMainWindow = { [openWindow] in
                openWindow(id: AppDelegate.mainWindowID)
            }
            if selection == nil { selection = store.profiles.first?.id }
        }
        .onChange(of: store.profiles) { previousProfiles, profiles in
            if profiles.count > previousProfiles.count {
                searchText = ""
                selection = profiles.last?.id
            } else if let selection, !profiles.contains(where: { $0.id == selection }) {
                self.selection = filteredProfiles.first?.id
            }
        }
        .onChange(of: searchText) { _, _ in
            if !filteredProfiles.contains(where: { $0.id == selection }) {
                selection = filteredProfiles.first?.id
            }
        }
    }

    private var filteredProfiles: [TunnelProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.profiles }
        return store.profiles.filter {
            $0.name.localizedStandardContains(query) ||
            "\($0.username)@\($0.host)".localizedStandardContains(query)
        }
    }

    private func addTunnel() {
        searchText = ""
        store.addProfile()
        selection = store.profiles.last?.id
    }

    private func deleteSelectedTunnel() {
        guard let selection, let profile = store.profiles.first(where: { $0.id == selection }) else { return }
        store.delete(profile)
    }

    private func importTunnel() {
        let panel = NSOpenPanel()
        panel.title = "Import Tunnel Profile"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.importProfile(from: url)
        } catch {
            showProfileError("Could Not Import Tunnel Profile", error: error)
        }
    }

    private func exportSelectedTunnel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard let profile = selectedProfile?.wrappedValue else { return }

        let panel = NSSavePanel()
        panel.title = "Export Tunnel Profile"
        panel.prompt = "Export"
        panel.message = "The file contains connection settings, including the identity-file path. Passwords and private keys stay on this Mac."
        panel.allowedContentTypes = [.json]
        let invalidCharacters = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let name = profile.name.components(separatedBy: invalidCharacters).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = (name.isEmpty ? "Tunnel Profile" : name) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try profile.export(to: url)
        } catch {
            showProfileError("Could Not Export Tunnel Profile", error: error)
        }
    }

    private var backupFileType: UTType {
        UTType(filenameExtension: TunnelBackup.fileExtension, conformingTo: .data) ?? .data
    }

    private func backupTunnels() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.title = "Back Up All Tunnels"
        panel.prompt = "Back Up"
        panel.message = "Save all tunnel settings and remembered SSH passwords in a passphrase-protected file."
        panel.allowedContentTypes = [backupFileType]
        panel.nameFieldStringValue = "FastSSHTunnel Backup.\(TunnelBackup.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url,
              let passphrase = backupPassphrase(creating: true) else { return }

        Task {
            do {
                try await store.createBackup(at: url, passphrase: passphrase)
            } catch {
                showProfileError("Could Not Back Up Tunnels", error: error)
            }
        }
    }

    private func restoreTunnels() {
        let panel = NSOpenPanel()
        panel.title = "Restore Tunnel Backup"
        panel.prompt = "Open"
        panel.allowedContentTypes = [backupFileType]
        guard panel.runModal() == .OK, let url = panel.url,
              let passphrase = backupPassphrase(creating: false) else { return }

        isOpeningBackup = true
        Task {
            defer { isOpeningBackup = false }
            do {
                let backup = try await Task.detached { try TunnelBackup.read(from: url, passphrase: passphrase) }.value
                let count = backup.entries.count
                let profileCount = "\(count) \(count == 1 ? "profile" : "profiles")"
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Restore Tunnel Backup?"
                alert.informativeText = "This backup contains \(profileCount). Restoring replaces the current tunnel profiles and remembered SSH passwords and stops any running tunnels."
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
                alert.addButton(withTitle: "Replace and Restore").hasDestructiveAction = true
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                try await store.restore(backup)
                searchText = ""
                selection = store.profiles.last?.id
                if let selection { store.notices[selection] = "Restored \(profileCount) from backup." }
            } catch {
                showProfileError("Could Not Restore Backup", error: error)
            }
        }
    }

    private func backupPassphrase(creating: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = creating ? "Set a Backup Passphrase" : "Unlock Tunnel Backup"
        alert.informativeText = creating
            ? "Use at least \(TunnelBackup.minimumPassphraseLength) characters. Keep this passphrase so you can restore the backup later."
            : "Enter the passphrase you used to create this backup."
        alert.addButton(withTitle: creating ? "Back Up" : "Unlock")
        alert.addButton(withTitle: "Cancel")

        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: creating ? 56 : 24))
        let passphrase = NSSecureTextField(frame: NSRect(x: 0, y: creating ? 32 : 0, width: 300, height: 24))
        passphrase.placeholderString = "Backup passphrase"
        passphrase.setAccessibilityLabel("Backup passphrase")
        fields.addSubview(passphrase)
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if creating {
            confirmation.placeholderString = "Confirm backup passphrase"
            confirmation.setAccessibilityLabel("Confirm backup passphrase")
            fields.addSubview(confirmation)
            passphrase.nextKeyView = confirmation
        }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = passphrase

        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            let value = passphrase.stringValue
            if !creating && !value.isEmpty { return value }
            if creating && value.count >= TunnelBackup.minimumPassphraseLength && value == confirmation.stringValue {
                return value
            }
            alert.informativeText = creating
                ? "Enter matching passphrases of at least \(TunnelBackup.minimumPassphraseLength) characters."
                : "Enter the backup passphrase to continue."
            alert.window.initialFirstResponder = passphrase
        }
        return nil
    }

    private func showProfileError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var selectedProfile: Binding<TunnelProfile>? {
        guard let selection, store.profiles.contains(where: { $0.id == selection }) else { return nil }
        return Binding(
            get: { store.profiles.first(where: { $0.id == selection }) ?? TunnelProfile() },
            set: { store.update($0) }
        )
    }
}

struct TunnelRow: View {
    let profile: TunnelProfile
    let state: TunnelState
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name.isEmpty ? "Untitled tunnel" : profile.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            HStack(spacing: 5) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(profile.host.isEmpty ? "Not configured" : "\(profile.username)@\(profile.host):\(profile.sshPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EmptyStateView: View {
    let addTunnel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No SSH tunnels", systemImage: "network")
        } description: {
            Text("Save a connection, start a secure SOCKS5 tunnel, and browse through it in Firefox.")
        } actions: {
            Button("Add Tunnel", action: addTunnel)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct EditableFieldStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color(white: 0.10) : .white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isFocused ? Color.accentColor : Color.primary.opacity(contrast == .increased ? 0.75 : 0.42),
                        lineWidth: isFocused || contrast == .increased ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

struct TunnelDetailView: View {
    @EnvironmentObject private var store: TunnelStore
    @Binding var profile: TunnelProfile
    @State private var savedProfile: TunnelProfile?
    @State private var saveError: String?
    @State private var savedCredential: TunnelCredential?
    @State private var isSaving = false
    @State private var isOpeningSSH = false
    @State private var sshLaunchError: String?
    @State private var isOpeningRemoteDesktop = false
    @State private var remoteDesktopLaunchError: String?

    // Network ports use plain decimal digits, independent of regional formatting.
    private static let portFormat = IntegerFormatStyle<Int>.number
        .grouping(.never)
        .locale(Locale(identifier: "en_US_POSIX"))

    var body: some View {
        let state = store.state(for: profile)
        let credentialIsLoading = store.loadingCredentials.contains(PasswordIdentity(profile))
        VStack(spacing: 0) {
            tunnelStatusHeader
                // Leave room for the split view's translucent navigation strip.
                .padding(.top, 54)
                // The settings tabs can be very tall. Keep the status text at
                // its natural height and let the forms scroll in the space left.
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            GeometryReader { available in
              TabView {
              Form {
                Section("Connection") {
                    LabeledContent("Name") {
                        TextField("Name", text: $profile.name)
                            .modifier(EditableFieldStyle())
                    }
                    LabeledContent("Host") {
                        TextField("Host", text: $profile.host, prompt: Text("ssh.example.com"))
                            .modifier(EditableFieldStyle())
                    }
                    LabeledContent("Username") {
                        TextField("Username", text: $profile.username, prompt: Text("ubuntu"))
                            .modifier(EditableFieldStyle())
                    }
                    HStack(spacing: 12) {
                        Text("SSH port").fixedSize()
                        TextField("SSH port", value: $profile.sshPort, format: Self.portFormat)
                            .modifier(EditableFieldStyle())
                            .frame(width: 96)
                        Text("SOCKS port").fixedSize()
                        TextField("SOCKS port", value: $profile.socksPort, format: Self.portFormat)
                            .modifier(EditableFieldStyle())
                            .frame(width: 96)
                        Spacer()
                    }
                }

                Section {
                    Text("New SSH host keys are accepted and saved automatically on the first connection. If a saved host key changes, the connection is blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
              }
              .formStyle(.grouped)
              .tabItem { Label("Connection", systemImage: "network") }

              Form {
                Section("Authentication") {
                    LabeledContent("Password (optional)") {
                        SecureField("SSH password", text: Binding(
                            get: { store.credential(for: profile).password },
                            set: { store.setPassword($0, for: profile) }
                        ), prompt: Text("Enter SSH password…"))
                        .modifier(EditableFieldStyle())
                        .disabled(credentialIsLoading)
                    }
                    Toggle("Remember password in macOS Keychain", isOn: Binding(
                        get: { store.credential(for: profile).remember },
                        set: { store.setRememberPassword($0, for: profile) }
                    ))
                    .disabled(credentialIsLoading)
                    Text("Use Save Connection to update Keychain. Without Remember, the password is kept only until you quit the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = store.credentialErrors[profile.id] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent("Identity file (optional)") {
                        HStack {
                            TextField("Identity file (optional)", text: $profile.identityFile, prompt: Text("Select an SSH key…"))
                                .modifier(EditableFieldStyle())
                            Button("Choose…", action: chooseIdentityFile)
                        }
                    }
                    Text("Enter a password or select an SSH key to connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

              }
              .formStyle(.grouped)
              .tabItem { Label("Authentication", systemImage: "key") }

              Form {
                Section("Firefox") {
                    LabeledContent("Page to open") {
                        TextField("Page to open", text: $profile.startPage, prompt: Text("https://example.com"))
                            .modifier(EditableFieldStyle())
                    }
                    Text("Firefox uses a separate profile whose SOCKS5 proxy and DNS are both routed through this tunnel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open in Firefox") { store.openInFirefox(profile) }
                        .disabled(state != .connected)
                }

              }
              .formStyle(.grouped)
              .tabItem { Label("Firefox", systemImage: "globe") }

              Form {
                Section("SSH to another device") {
                    LabeledContent("Device host") {
                        TextField("Device host", text: sshDevice.host, prompt: Text("192.168.1.10 or device.internal"))
                            .modifier(EditableFieldStyle())
                    }
                    LabeledContent("Device username") {
                        TextField("Device username", text: sshDevice.username, prompt: Text("Enter device SSH username"))
                            .modifier(EditableFieldStyle())
                    }
                    LabeledContent("Device SSH port") {
                        TextField("Device SSH port", value: sshDevice.port, format: Self.portFormat)
                            .modifier(EditableFieldStyle())
                            .frame(width: 96)
                    }
                    Text("Connect the tunnel, then open an interactive SSH session in Terminal. The device is reached through this tunnel; enter its password in Terminal or use a local SSH key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: openDeviceSSH) {
                        Label(isOpeningSSH ? "Opening Terminal…" : "Open SSH in Terminal", systemImage: "terminal")
                    }
                    .disabled(state != .connected || isOpeningSSH)
                    if let sshLaunchError {
                        Text(sshLaunchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

              }
              .formStyle(.grouped)
              .tabItem { Label("Device SSH", systemImage: "terminal") }

              remoteDesktopTab
                .tabItem { Label("Remote Desktop", systemImage: "display") }

              staticPortTab
                .tabItem { Label("Static Port", systemImage: "arrow.left.arrow.right") }
              }
              .frame(width: available.size.width, height: available.size.height, alignment: .topLeading)
              .clipped()
            }
            .padding()
            saveBar
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        // Let the split view size the detail pane to the window, even when the
        // status text or save bar asks for extra height at a narrow width.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task(id: PasswordIdentity(profile)) {
            await store.loadCredential(for: profile)
        }
        .alert("Authentication Required", isPresented: Binding(
            get: { store.missingAuthenticationProfileID == profile.id },
            set: { if !$0 { store.missingAuthenticationProfileID = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Enter an SSH password or select an SSH key to connect.")
        }
    }

    private var saveBar: some View {
        let credentialIsLoading = store.loadingCredentials.contains(PasswordIdentity(profile))
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Button(action: saveConnection) {
                    Label(isSaving ? "Saving…" : "Save Connection", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isSaving || credentialIsLoading)

                Spacer()

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                } else if savedProfile == profile && savedCredential == store.credential(for: profile) {
                    Label("Connection saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Changes are also saved automatically.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding()
            .background(.bar)
        }
    }

    private var tunnelStatusHeader: some View {
        let state = store.state(for: profile)
        let credentialIsLoading = store.loadingCredentials.contains(PasswordIdentity(profile))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tunnel status")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("·")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(profile.name.isEmpty ? "Untitled tunnel" : profile.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 8) {
                Circle().fill(state.color).frame(width: 10, height: 10)
                Text(state.title).fontWeight(.medium)
                Spacer()
                Text(verbatim: "socks5://127.0.0.1:\(store.displayedSOCKSPort(for: profile))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let notice = store.notices[profile.id] {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(stateMessageColor(state))
                    .lineLimit(2)
                    .help(notice)
                    .textSelection(.enabled)
            }
            if state == .connected {
                TunnelTrafficView(
                    statistics: store.trafficStatistics[profile.id],
                    error: store.trafficErrors[profile.id]
                )
            }
            HStack {
                if state == .connected || state == .connecting {
                    Button("Disconnect") { store.disconnect(profile) }
                } else {
                    Button("Connect") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        store.connect(profile)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(credentialIsLoading)
                }
                Button("Connect & Browse") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    store.connectAndBrowse(profile)
                }
                .disabled(state == .connecting || credentialIsLoading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func saveConnection() {
        guard !isSaving else { return }
        // Commit any active field editor before persisting, including port fields.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let profileToSave = profile
        let credentialToSave = store.credential(for: profile)
        guard store.update(profileToSave) else {
            saveError = "Could not save this connection. Please try again."
            return
        }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await store.saveCredential(credentialToSave)
                savedProfile = profileToSave
                savedCredential = credentialToSave
            } catch {
                savedProfile = nil
                savedCredential = nil
                saveError = "Could not update Keychain: \(error.localizedDescription)"
            }
        }
    }

    private var sshDevice: Binding<SSHDevice> {
        Binding(
            get: { profile.sshDevice ?? SSHDevice() },
            set: {
                profile.sshDevice = $0
                sshLaunchError = nil
            }
        )
    }

    private var remoteDesktopTab: some View {
        let settings = Binding(
            get: { profile.remoteDesktop ?? RemoteDesktop() },
            set: {
                profile.remoteDesktop = $0
                remoteDesktopLaunchError = nil
            }
        )
        let configured = profile.enabledRemoteDesktop
        let active = store.activeRemoteDesktop(for: profile)
        let state = store.state(for: profile)
        return Form {
            Section("Remote Desktop over SSH") {
                Toggle("Enable Remote Desktop forwarding", isOn: settings.isEnabled)
                LabeledContent("Windows PC host") {
                    TextField("Windows PC host", text: settings.host, prompt: Text("pc.internal or 192.168.1.10"))
                        .modifier(EditableFieldStyle())
                }
                LabeledContent("Windows PC port") {
                    TextField("Windows PC port", value: settings.remotePort, format: Self.portFormat)
                        .modifier(EditableFieldStyle())
                        .frame(width: 96)
                }
                LabeledContent("Local port on this Mac") {
                    TextField("Local port on this Mac", value: settings.localPort, format: Self.portFormat)
                        .modifier(EditableFieldStyle())
                        .frame(width: 96)
                }
                Text("Use a Windows PC hostname or IP address reachable from the SSH server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let forward = active ?? configured {
                Section("Connect to the Windows PC") {
                    LabeledContent("PC name in Windows App") {
                        Text(verbatim: forward.localAddress)
                            .monospaced()
                            .textSelection(.enabled)
                    }
                    if (state == .connected || state == .connecting) && active != configured {
                        Text("Disconnect and reconnect the tunnel to apply your Remote Desktop changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use Connect above, then open Remote Desktop. Keep the tunnel connected while using the Windows PC.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(action: openRemoteDesktop) {
                        Label(isOpeningRemoteDesktop ? "Opening Remote Desktop…" : "Open Remote Desktop", systemImage: "display")
                    }
                    .disabled(state != .connected || active == nil || active != configured || isOpeningRemoteDesktop)
                    if let remoteDesktopLaunchError {
                        Text(remoteDesktopLaunchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var staticPortTab: some View {
        let settings = Binding(
            get: { profile.staticPort ?? StaticPortForward() },
            set: { profile.staticPort = $0 }
        )
        let active = store.activeStaticPort(for: profile)
        let state = store.state(for: profile)
        return Form {
            Section("Static port forwarding") {
                Toggle("Enable static port forwarding", isOn: settings.isEnabled)
                LabeledContent("Destination host") {
                    TextField("Destination host", text: settings.host, prompt: Text("localhost or service.internal"))
                        .modifier(EditableFieldStyle())
                }
                LabeledContent("Destination port") {
                    TextField("Destination port", value: settings.remotePort, format: Self.portFormat)
                        .modifier(EditableFieldStyle())
                        .frame(width: 96)
                }
                LabeledContent("Local port on this Mac") {
                    TextField("Local port on this Mac", value: settings.localPort, format: Self.portFormat)
                        .modifier(EditableFieldStyle())
                        .frame(width: 96)
                }
                Text("The destination must be reachable from the SSH server. Connect your application to the local address below while the tunnel is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let forward = active ?? profile.enabledStaticPort {
                    LabeledContent("Local address") {
                        Text(verbatim: forward.localAddress).monospaced().textSelection(.enabled)
                    }
                }
                if (state == .connected || state == .connecting) && active != profile.enabledStaticPort {
                    Text("Disconnect and reconnect the tunnel to apply your static port changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openRemoteDesktop() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let connection = profile
        isOpeningRemoteDesktop = true
        remoteDesktopLaunchError = nil
        Task { @MainActor in
            defer { isOpeningRemoteDesktop = false }
            do {
                try await store.openRemoteDesktop(connection)
            } catch {
                remoteDesktopLaunchError = error.localizedDescription
            }
        }
    }

    private func openDeviceSSH() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let connection = profile
        isOpeningSSH = true
        sshLaunchError = nil
        Task { @MainActor in
            defer { isOpeningSSH = false }
            do {
                try await store.openSSH(connection)
            } catch {
                sshLaunchError = error.localizedDescription
            }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Key"
        if panel.runModal() == .OK, let url = panel.url {
            profile.identityFile = url.path
        }
    }

    private func stateMessageColor(_ state: TunnelState) -> Color {
        if case .failed = state { return .red }
        return .secondary
    }
}

#if DEBUG
#Preview("FastSSHTunnel") {
    let sample = TunnelProfile(
        name: "Example tunnel",
        host: "ssh.example.com",
        username: "admin",
        sshDevice: SSHDevice(host: "192.168.1.10", username: "admin"),
        remoteDesktop: RemoteDesktop(isEnabled: true, host: "pc.internal")
    )
    ContentView(publicIPAddress: PublicIPAddressStore(previewAddress: "203.0.113.42"))
        .environmentObject(TunnelStore(previewProfiles: [sample]))
        .environmentObject(AppDelegate())
        .frame(width: 1100, height: 760)
}
#endif
