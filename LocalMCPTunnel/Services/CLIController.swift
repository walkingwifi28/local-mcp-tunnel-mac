import Combine
import Foundation

@MainActor
final class CLIController: ObservableObject {
    @Published private(set) var tunnelState: ProcessState = .stopped
    @Published private(set) var localMCPState: ProcessState = .stopped
    @Published private(set) var tunnelLogText = ""
    @Published private(set) var localMCPLogText = ""
    @Published private(set) var permissionMode: PermissionMode = .ask
    @Published private(set) var allowedDirectories: [String] = []
    @Published var presentedError: String?

    private enum DefaultsKeys {
        static let permissionMode = "permissionMode"
    }

    private enum TunnelRestartPolicy {
        static let maxAttempts = 5
        static let initialDelay: TimeInterval = 1
        static let maxDelay: TimeInterval = 30
        static let resetAfter: TimeInterval = 60

        static func delay(forAttempt attempt: Int) -> TimeInterval {
            guard attempt > 0 else { return 0 }
            var delay = initialDelay
            if attempt > 1 {
                for _ in 1..<attempt {
                    delay = min(delay * 2, maxDelay)
                }
            }
            return delay
        }
    }

    private struct TunnelLaunchSpec {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: String
    }

    enum LogSource: String, CaseIterable, Identifiable {
        case tunnel
        case localMCP

        var id: Self { self }

        var label: String {
            switch self {
            case .tunnel:
                return "tunnel-client"
            case .localMCP:
                return "local-mcp"
            }
        }
    }

    private var initializationProcess: ManagedProcess?
    private var tunnelProcess: ManagedProcess?
    private var localMCPProcess: ManagedProcess?
    private var tunnelRestartWorkItem: DispatchWorkItem?
    private var tunnelRestartAttempts = 0
    private var tunnelStartedAt: Date?
    private var tunnelLaunchSpec: TunnelLaunchSpec?
    private var tunnelStopRequested = false
    private var localMCPStopRequested = false
    private var redactedValues: [String] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: DefaultsKeys.permissionMode) ?? "") ?? .ask
    }

    var canStopTunnel: Bool {
        tunnelProcess?.isRunning == true || tunnelRestartWorkItem != nil
    }

    func initializeTunnel(using configuration: CLIConfiguration) {
        guard validate(configuration), initializationProcess == nil, tunnelProcess == nil, tunnelRestartWorkItem == nil else { return }

        do {
            rememberSecret(configuration.controlPlaneAPIKey)
            let environment = ShellPathResolver.augmentedEnvironment(apiKey: configuration.controlPlaneAPIKey)
            let executable = try ShellPathResolver.resolveExecutable(configuration.tunnelClientExecutable, environment: environment)
            let arguments = [
                "init",
                "--sample", configuration.sampleName,
                "--profile", configuration.profileName,
                "--tunnel-id", configuration.tunnelID,
                "--mcp-command", ShellPathResolver.expandHomeVariables(configuration.mcpCommand),
                "--force"
            ]
            appendLog("[tunnel:init] \(displayCommand(executable: executable.path, arguments: arguments))", to: .tunnel)
            tunnelState = .starting
            let process = try ManagedProcess(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: configuration.workingDirectory,
                label: "tunnel:init",
                onOutput: { [weak self] line in self?.appendLog(line, to: .tunnel) },
                onTermination: { [weak self] status in
                    guard let self else { return }
                    self.initializationProcess = nil
                    self.tunnelState = status == 0 ? .stopped : .failed("Exit code: \(status)")
                }
            )
            initializationProcess = process
            try process.start()
        } catch {
            initializationProcess = nil
            tunnelState = .failed(error.localizedDescription)
            present(error, source: .tunnel)
        }
    }

    func startTunnel(using configuration: CLIConfiguration) {
        guard validate(configuration), initializationProcess == nil, tunnelProcess == nil, tunnelRestartWorkItem == nil else { return }
        do {
            rememberSecret(configuration.controlPlaneAPIKey)
            let environment = ShellPathResolver.augmentedEnvironment(apiKey: configuration.controlPlaneAPIKey)
            let executable = try ShellPathResolver.resolveExecutable(configuration.tunnelClientExecutable, environment: environment)
            let arguments = ["run", "--profile", configuration.profileName]
            let spec = TunnelLaunchSpec(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: configuration.workingDirectory
            )

            appendLog("[tunnel] \(displayCommand(executable: executable.path, arguments: arguments))", to: .tunnel)
            tunnelState = .starting
            tunnelStopRequested = false
            tunnelRestartWorkItem?.cancel()
            tunnelRestartWorkItem = nil
            tunnelRestartAttempts = 0
            tunnelStartedAt = nil
            tunnelLaunchSpec = spec

            try launchTunnel(using: spec)
        } catch {
            tunnelProcess = nil
            tunnelLaunchSpec = nil
            tunnelState = .failed(error.localizedDescription)
            present(error, source: .tunnel)
        }
    }

    func stopTunnel() {
        guard tunnelProcess != nil || tunnelRestartWorkItem != nil else { return }
        tunnelStopRequested = true
        tunnelRestartWorkItem?.cancel()
        tunnelRestartWorkItem = nil

        if let tunnelProcess {
            tunnelState = .stopping
            appendLog("[tunnel] Stop request sent.", to: .tunnel)
            tunnelProcess.stop()
        } else {
            appendLog("[tunnel] Manual stop request cancelled automatic restart.", to: .tunnel)
            tunnelLaunchSpec = nil
            tunnelStartedAt = nil
            tunnelRestartAttempts = 0
            tunnelState = .stopped
        }
    }

    private func launchTunnel(using spec: TunnelLaunchSpec, restartAttempt: Int? = nil) throws {
        let process = try ManagedProcess(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: spec.environment,
            workingDirectory: spec.workingDirectory,
            label: "tunnel",
            onOutput: { [weak self] line in self?.appendLog(line, to: .tunnel) },
            onTermination: { [weak self] status in
                self?.handleTunnelTermination(status: status)
            }
        )

        tunnelProcess = process
        do {
            try process.start()
        } catch {
            tunnelProcess = nil
            throw error
        }

        tunnelStartedAt = Date()
        tunnelState = .running(processIdentifier: process.processIdentifier)
        if restartAttempt != nil {
            appendLog("[tunnel] tunnel-client restarted successfully.", to: .tunnel)
        }
    }

    private func handleTunnelTermination(status: Int32) {
        let uptime = tunnelStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        tunnelProcess = nil
        tunnelStartedAt = nil

        if tunnelStopRequested {
            tunnelStopRequested = false
            tunnelRestartWorkItem?.cancel()
            tunnelRestartWorkItem = nil
            tunnelRestartAttempts = 0
            tunnelLaunchSpec = nil
            tunnelState = .stopped
            return
        }

        guard let spec = tunnelLaunchSpec else {
            tunnelState = .failed("Exit code: \(status)")
            return
        }

        if uptime >= TunnelRestartPolicy.resetAfter {
            tunnelRestartAttempts = 0
        }
        scheduleTunnelRestart(using: spec, lastError: "Exit code: \(status)")
    }

    private func scheduleTunnelRestart(using spec: TunnelLaunchSpec, lastError: String) {
        guard !tunnelStopRequested else {
            tunnelState = .stopped
            return
        }

        guard tunnelRestartAttempts < TunnelRestartPolicy.maxAttempts else {
            let message = "\(lastError); automatic restart limit reached (\(TunnelRestartPolicy.maxAttempts) attempts)"
            appendLog("[tunnel] \(message)", to: .tunnel)
            tunnelRestartWorkItem = nil
            tunnelLaunchSpec = nil
            tunnelState = .failed(message)
            return
        }

        tunnelRestartAttempts += 1
        let attempt = tunnelRestartAttempts
        let delay = TunnelRestartPolicy.delay(forAttempt: attempt)
        tunnelState = .starting
        appendLog(
            "[tunnel] Unexpected exit. Restart attempt \(attempt)/\(TunnelRestartPolicy.maxAttempts) in \(Int(delay * 1_000)) ms.",
            to: .tunnel
        )

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.tunnelStopRequested else {
                    self.tunnelRestartWorkItem = nil
                    self.tunnelState = .stopped
                    return
                }

                self.tunnelRestartWorkItem = nil
                self.appendLog(
                    "[tunnel] Restarting tunnel-client (attempt \(attempt)/\(TunnelRestartPolicy.maxAttempts)): \(self.displayCommand(executable: spec.executable.path, arguments: spec.arguments))",
                    to: .tunnel
                )

                do {
                    try self.launchTunnel(using: spec, restartAttempt: attempt)
                } catch {
                    let message = error.localizedDescription
                    self.appendLog("[tunnel] Restart attempt \(attempt) failed: \(message)", to: .tunnel)
                    self.scheduleTunnelRestart(using: spec, lastError: message)
                }
            }
        }
        tunnelRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func startLocalMCP(using configuration: CLIConfiguration) {
        guard validate(configuration), localMCPProcess == nil else { return }
        do {
            rememberSecret(configuration.controlPlaneAPIKey)
            let environment = ShellPathResolver.augmentedEnvironment(apiKey: configuration.controlPlaneAPIKey)
            let executable = try ShellPathResolver.resolveExecutable(configuration.localMCPExecutable, environment: environment)
            let arguments = ["start", configuration.sessionID]
            appendLog("[local-mcp] \(displayCommand(executable: executable.path, arguments: arguments))", to: .localMCP)
            localMCPState = .starting
            localMCPStopRequested = false

            let process = try ManagedProcess(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: configuration.workingDirectory,
                label: "local-mcp",
                streamNameOverride: "stdout",
                onOutput: { [weak self] line in self?.appendLog(line, to: .localMCP) },
                onTermination: { [weak self] status in
                    guard let self else { return }
                    self.localMCPProcess = nil
                    self.allowedDirectories = []
                    let wasRequested = self.localMCPStopRequested
                    self.localMCPStopRequested = false
                    self.localMCPState = (wasRequested || status == 0) ? .stopped : .failed("Exit code: \(status)")
                }
            )
            localMCPProcess = process
            try process.start()
            localMCPState = .running(processIdentifier: process.processIdentifier)
            resetAllowedDirectories(workingDirectory: configuration.workingDirectory)
            applyPermissionMode(to: process)
            applyAllowedDirectories(configuration.normalizedAllowedDirectories, to: process)
        } catch {
            localMCPProcess = nil
            localMCPState = .failed(error.localizedDescription)
            present(error, source: .localMCP)
        }
    }

    func stopLocalMCP() {
        guard let localMCPProcess else { return }
        localMCPStopRequested = true
        localMCPState = .stopping
        appendLog("[local-mcp] Stop request sent.", to: .localMCP)
        localMCPProcess.stop()
    }

    func sendPermission(_ command: PermissionCommand) {
        guard let process = localMCPProcess, process.isRunning else {
            presentedError = "Please start local-mcp first."
            return
        }
        do {
            try process.send(command.commandLine)
            updatePermissionModeIfNeeded(for: command)
            updateAllowedDirectoriesIfNeeded(for: command)
            appendLog("[local-mcp:stdin] \(command.commandLine)", to: .localMCP)
        } catch {
            present(error, source: .localMCP)
        }
    }

    func canSendInput(to source: LogSource) -> Bool {
        activeInputTarget(for: source) != nil
    }

    @discardableResult
    func sendInput(_ input: String, to source: LogSource) -> Bool {
        let normalized = input.trimmingCharacters(in: .newlines)
        guard !normalized.isEmpty else { return false }
        guard let target = activeInputTarget(for: source) else {
            presentedError = "\(source.label) is not running."
            return false
        }

        do {
            try target.process.send(normalized)
            if source == .localMCP {
                updatePermissionModeIfNeeded(for: normalized)
                updateAllowedDirectoriesIfNeeded(for: normalized)
            }
            appendLog("[\(target.logLabel):stdin] \(normalized)", to: source)
            return true
        } catch {
            present(error, source: source)
            return false
        }
    }

    func logText(for source: LogSource) -> String {
        switch source {
        case .tunnel:
            return tunnelLogText
        case .localMCP:
            return localMCPLogText
        }
    }

    func clearLog(for source: LogSource) {
        switch source {
        case .tunnel:
            tunnelLogText = ""
        case .localMCP:
            localMCPLogText = ""
        }
    }

    func terminateAll() {
        tunnelStopRequested = true
        localMCPStopRequested = true
        tunnelRestartWorkItem?.cancel()
        tunnelRestartWorkItem = nil
        tunnelLaunchSpec = nil
        tunnelStartedAt = nil
        tunnelRestartAttempts = 0

        initializationProcess?.forceStop()
        tunnelProcess?.forceStop()
        localMCPProcess?.forceStop()
        initializationProcess = nil
        tunnelProcess = nil
        localMCPProcess = nil
        allowedDirectories = []
        tunnelState = .stopped
        localMCPState = .stopped
    }

    private func updatePermissionModeIfNeeded(for command: PermissionCommand) {
        switch command {
        case .ask:
            setPermissionMode(.ask)
        case .yolo:
            setPermissionMode(.yolo)
        case .allow, .revoke, .list, .status:
            break
        }
    }

    private func updatePermissionModeIfNeeded(for input: String) {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines) {
        case PermissionCommand.ask.commandLine:
            setPermissionMode(.ask)
        case PermissionCommand.yolo.commandLine:
            setPermissionMode(.yolo)
        default:
            break
        }
    }

    private func updateAllowedDirectoriesIfNeeded(for command: PermissionCommand) {
        switch command {
        case let .allow(directory):
            addAllowedDirectory(directory)
        case let .revoke(directory):
            removeAllowedDirectory(directory)
        case .ask, .yolo, .list, .status:
            break
        }
    }

    private func updateAllowedDirectoriesIfNeeded(for input: String) {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowPrefix = "/permission allow "
        let revokePrefix = "/permission revoke "

        if normalized.hasPrefix(allowPrefix) {
            addAllowedDirectory(String(normalized.dropFirst(allowPrefix.count)))
        } else if normalized.hasPrefix(revokePrefix) {
            removeAllowedDirectory(String(normalized.dropFirst(revokePrefix.count)))
        }
    }

    private func resetAllowedDirectories(workingDirectory: String) {
        allowedDirectories = []
        addAllowedDirectory(workingDirectory)
    }

    private func addAllowedDirectory(_ directory: String) {
        guard let normalized = normalizedDirectory(directory), !allowedDirectories.contains(normalized) else { return }
        allowedDirectories.append(normalized)
    }

    private func removeAllowedDirectory(_ directory: String) {
        guard let normalized = normalizedDirectory(directory) else { return }
        allowedDirectories.removeAll { $0 == normalized }
    }

    private func normalizedDirectory(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: ShellPathResolver.expanded(trimmed), isDirectory: true)
            .standardizedFileURL
            .path
    }

    private func setPermissionMode(_ mode: PermissionMode) {
        permissionMode = mode
        defaults.set(mode.rawValue, forKey: DefaultsKeys.permissionMode)
    }

    private func applyPermissionMode(to process: ManagedProcess) {
        let command: PermissionCommand = permissionMode == .yolo ? .yolo : .ask
        appendLog("[local-mcp] Applying saved Permission Mode (\(permissionMode.label)).", to: .localMCP)
        do {
            try process.send(command.commandLine)
            appendLog("[local-mcp:stdin] \(command.commandLine)", to: .localMCP)
        } catch {
            appendLog("[error] Failed to automatically apply Permission Mode: \(error.localizedDescription)", to: .localMCP)
            presentedError = "Failed to automatically apply Permission Mode."
        }
    }

    private func applyAllowedDirectories(_ directories: [String], to process: ManagedProcess) {
        guard !directories.isEmpty else { return }

        appendLog("[local-mcp] Applying automatic allow at startup (\(directories.count) items).", to: .localMCP)
        for directory in directories {
            let command = PermissionCommand.allow(directory).commandLine
            do {
                try process.send(command)
                addAllowedDirectory(directory)
                appendLog("[local-mcp:stdin] \(command)", to: .localMCP)
            } catch {
                appendLog("[error] Failed to auto-allow: \(directory) - \(error.localizedDescription)", to: .localMCP)
                presentedError = "Failed to auto-allow at startup: \(directory)"
                break
            }
        }
    }

    private func activeInputTarget(for source: LogSource) -> (process: ManagedProcess, logLabel: String)? {
        switch source {
        case .tunnel:
            if let tunnelProcess, tunnelProcess.isRunning {
                return (tunnelProcess, "tunnel")
            }
            if let initializationProcess, initializationProcess.isRunning {
                return (initializationProcess, "tunnel:init")
            }
            return nil
        case .localMCP:
            guard let localMCPProcess, localMCPProcess.isRunning else { return nil }
            return (localMCPProcess, "local-mcp")
        }
    }

    private func validate(_ configuration: CLIConfiguration) -> Bool {
        if let message = configuration.validationMessage {
            presentedError = message
            return false
        }
        return true
    }

    private func present(_ error: Error, source: LogSource? = nil) {
        if let source {
            appendLog("[error] \(error.localizedDescription)", to: source)
        }
        presentedError = error.localizedDescription
    }

    private func appendLog(_ message: String, to source: LogSource) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let normalized = message.hasSuffix("\n") ? String(message.dropLast()) : message
        let sanitized = redactedValues.reduce(normalized) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "••••••••")
        }
        let entry = "[\(timestamp)] \(sanitized)\n"
        switch source {
        case .tunnel:
            tunnelLogText += entry
        case .localMCP:
            localMCPLogText += entry
        }
    }

    private func rememberSecret(_ value: String) {
        guard !value.isEmpty, !redactedValues.contains(value) else { return }
        redactedValues.append(value)
    }

    private func displayCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map { value in
            value.contains(" ") ? "\"\(value)\"" : value
        }.joined(separator: " ")
    }
}

private final class ManagedProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let label: String
    private let streamNameOverride: String?
    private let onOutput: @MainActor (String) -> Void
    private let onTermination: @MainActor (Int32) -> Void
    private var stopFallback: DispatchWorkItem?

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        label: String,
        streamNameOverride: String? = nil,
        onOutput: @escaping @MainActor (String) -> Void,
        onTermination: @escaping @MainActor (Int32) -> Void
    ) throws {
        self.label = label
        self.streamNameOverride = streamNameOverride
        self.onOutput = onOutput
        self.onTermination = onTermination
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let expandedDirectory = ShellPathResolver.expanded(workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessError.invalidWorkingDirectory(expandedDirectory)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: expandedDirectory, isDirectory: true)

        stdoutPipe.fileHandleForReading.readabilityHandler = makeReadHandler(stream: "stdout")
        stderrPipe.fileHandleForReading.readabilityHandler = makeReadHandler(stream: "stderr")
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.stopFallback?.cancel()
            self.closePipes()
            Task { @MainActor in
                self.onOutput("[\(self.label)] Finished (code: \(process.terminationStatus))")
                self.onTermination(process.terminationStatus)
            }
        }
    }

    func start() throws {
        try process.run()
    }

    func send(_ command: String) throws {
        guard process.isRunning else { throw ProcessError.notRunning }
        guard let data = (command + "\n").data(using: .utf8) else { throw ProcessError.encodingFailed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
        }
        stopFallback = fallback
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: fallback)
    }

    func forceStop() {
        stopFallback?.cancel()
        if process.isRunning { process.terminate() }
        closePipes()
    }

    private func makeReadHandler(stream: String) -> (FileHandle) -> Void {
        { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines where !line.isEmpty {
                let outputLabel = "\(self.label):\(self.streamNameOverride ?? stream)"
                Task { @MainActor in
                    self.onOutput("[\(outputLabel)] \(line)")
                }
            }
        }
    }

    private func closePipes() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    enum ProcessError: LocalizedError {
        case invalidWorkingDirectory(String)
        case notRunning
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case let .invalidWorkingDirectory(path):
                return "Working directory does not exist: \(path)"
            case .notRunning:
                return "The process is not running."
            case .encodingFailed:
                return "Failed to convert the command to UTF-8."
            }
        }
    }
}
