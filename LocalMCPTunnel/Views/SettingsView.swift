import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saveButtonState: SaveButtonState = .idle
    @State private var saveResetTask: Task<Void, Never>?
    @State private var updateButtonState: UpdateButtonState = .idle
    @State private var updateButtonResetTask: Task<Void, Never>?
    @State private var tunnelClientStatus = "Checking tunnel-client..."
    @State private var tunnelClientCheckID = UUID()
    @StateObject private var updateService = AppUpdateService()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Runtime Environment") {
                    HStack {
                        TextField("Working Directory", text: $settings.workingDirectory)
                        Button("Select") { chooseWorkingDirectory() }
                    }
                }
                
                Section {
                    TextField("Profile Name", text: $settings.profileName)
                    TextField("Tunnel ID", text: $settings.tunnelID)
                    TextField("Sample Name", text: $settings.sampleName)
                    TextField("tunnel-client", text: $settings.tunnelClientExecutable)
                    Text(tunnelClientStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Check tunnel-client") { tunnelClientCheckID = UUID() }
                    Text("Install: brew install openai/tools/tunnel-client\nUpdate: brew update && brew upgrade openai/tools/tunnel-client")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Link("Official installation guide", destination: URL(string: "https://github.com/openai/tunnel-client#install-with-homebrew")!)
                    SecureField("CONTROL_PLANE_API_KEY", text: $settings.controlPlaneAPIKey)
                } header: {
                    HStack {
                        Text("Tunnel Client")
                        Spacer()
                        Link(destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Open OpenAI Platform")
                        .accessibilityLabel("Open OpenAI Platform in the browser")
                    }
                }

                Section("local-mcp") {
                    TextField("Session ID", text: $settings.sessionID)
                    TextField("local-mcp", text: $settings.localMCPExecutable)
                    TextField("MCP Command", text: $settings.mcpCommand)
                }

                Section("Auto-allow on startup") {
                    if settings.allowedDirectories.isEmpty {
                        Text("No directories are registered.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.allowedDirectories, id: \.self) { directory in
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(directory)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(directory)
                                Spacer()
                                Button {
                                    settings.removeAllowedDirectory(directory)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this directory")
                            }
                        }
                    }

                    HStack {
                        Button("Add Directory...") {
                            chooseAllowedDirectories()
                        }
                        if !settings.allowedDirectories.isEmpty {
                            Button("Delete All", role: .destructive) {
                                settings.allowedDirectories.removeAll()
                            }
                        }
                        Spacer()
                    }

                    Text("Immediately after starting local-mcp, it automatically sends `/permission allow` to each registered directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("Update Application") {
                    LabeledContent("Current version") {
                        Text("v\(updateService.currentVersion)")
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        updateStatus
                        Spacer(minLength: 12)
                        updateButton
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            saveFooter
        }
        .frame(width: 660, height: 680)
        .onAppear {
            saveResetTask?.cancel()
            saveResetTask = nil
            saveButtonState = .idle
        }
        .task(id: "\(settings.tunnelClientExecutable)-\(tunnelClientCheckID)") {
            await checkTunnelClient()
        }
        .task {
            updateService.checkForUpdatesIfNeeded()
        }
        .onChange(of: updateService.state) { _, newState in
            handleUpdateServiceStateChange(newState)
        }
        .onDisappear {
            saveResetTask?.cancel()
            updateButtonResetTask?.cancel()
        }
    }

    @MainActor
    private func checkTunnelClient() async {
        tunnelClientStatus = "Checking tunnel-client..."
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        do {
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                tunnelClientStatus = "Unable to create the version-check output file."
                return
            }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            var environment = ShellPathResolver.augmentedEnvironment()
            environment.removeValue(forKey: "CONTROL_PLANE_API_KEY")
            environment.removeValue(forKey: "OPENAI_ADMIN_KEY")
            let executable = try ShellPathResolver.resolveExecutable(settings.tunnelClientExecutable, environment: environment)
            process.executableURL = executable
            process.arguments = ["--version"]
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
            }
            for _ in 0..<50 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !process.isRunning else {
                tunnelClientStatus = "\(executable.path) — Version check timed out."
                return
            }
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 4096) ?? Data()
            let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            tunnelClientStatus = process.terminationStatus == 0 && !version.isEmpty
                ? "\(executable.path)\n\(version)"
                : "\(executable.path) — Version check failed (exit \(process.terminationStatus))."
        } catch is CancellationError {
            // The next check owns the displayed status.
        } catch {
            tunnelClientStatus = error.localizedDescription
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateService.state {
        case .idle:
            Text("Check for the latest version on GitHub Releases.")
                .foregroundStyle(.secondary)
        case .checking:
            Label("Checking for updates...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .upToDate(let latestVersion):
            Label("This is the latest version. v\(latestVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable(let release):
            Label("v\(release.version) is available.", systemImage: "arrow.down.circle.fill")
        case .downloading(let release):
            Label("v\(release.version) downloading and verifying...", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .installing(let release):
            Label("v\(release.version) installing. It will restart upon completion...", systemImage: "gearshape.2")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updateButton: some View {
        Button(action: handleUpdateButton) {
            ZStack {
                animatedButtonFace(isVisible: updateButtonState == .idle) {
                    Text("Check for updates")
                }

                animatedButtonFace(isVisible: updateButtonState == .checking) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Checking for updates...")
                }

                animatedButtonFace(isVisible: updateButtonState == .upToDate) {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                    Text("Latest version")
                }

                animatedButtonFace(isVisible: updateButtonState == .updateAvailable) {
                    Image(systemName: "arrow.down")
                        .fontWeight(.semibold)
                    Text(updateAvailableButtonTitle)
                }

                animatedButtonFace(isVisible: updateButtonState == .downloading) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Fetching...")
                }

                animatedButtonFace(isVisible: updateButtonState == .installing) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Updating...")
                }

                animatedButtonFace(isVisible: updateButtonState == .failure) {
                    Image(systemName: "exclamationmark")
                        .fontWeight(.semibold)
                    Text("Retry")
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 180, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(updateButtonBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(saveAnimation, value: updateButtonState)
        }
        .buttonStyle(.plain)
        .disabled(updateService.isBusy)
        .accessibilityLabel(updateButtonAccessibilityLabel)
    }

    private var updateAvailableButtonTitle: String {
        guard case .updateAvailable(let release) = updateService.state else {
            return "Update"
        }
        return "Updated to v\(release.version)"
    }

    private var updateButtonBackground: Color {
        switch updateButtonState {
        case .failure:
            return Color(red: 112 / 255, green: 48 / 255, blue: 48 / 255)
        case .idle, .checking, .upToDate, .updateAvailable, .downloading, .installing:
            return Color(red: 60 / 255, green: 62 / 255, blue: 64 / 255)
        }
    }

    private var updateButtonAccessibilityLabel: String {
        switch updateButtonState {
        case .idle:
            return "Check for app updates."
        case .checking:
            return "Checking for app updates."
        case .upToDate:
            return "The app is up to date."
        case .updateAvailable:
            if case .updateAvailable(let release) = updateService.state {
                return "Update to version \(release.version)."
            }
            return "Update app."
        case .downloading:
            return "Downloading app update."
        case .installing:
            return "Updating app."
        case .failure:
            return "Failed to update the app. Retry."
        }
    }

    private func handleUpdateButton() {
        if case .updateAvailable = updateService.state {
            updateService.installAvailableUpdate()
        } else {
            updateService.checkForUpdates()
        }
    }

    private func handleUpdateServiceStateChange(_ state: AppUpdateService.State) {
        updateButtonResetTask?.cancel()

        let nextState: UpdateButtonState
        switch state {
        case .idle:
            nextState = .idle
        case .checking:
            nextState = .checking
        case .upToDate:
            nextState = .upToDate
        case .updateAvailable:
            nextState = .updateAvailable
        case .downloading:
            nextState = .downloading
        case .installing:
            nextState = .installing
        case .failed:
            nextState = .failure
        }

        withAnimation(saveAnimation) {
            updateButtonState = nextState
        }

        guard nextState == .upToDate else { return }

        updateButtonResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, case .upToDate = updateService.state else { return }

            withAnimation(saveAnimation) {
                updateButtonState = .idle
            }
        }
    }

    private var saveFooter: some View {
        HStack(spacing: 12) {
            if let saveMessage = settings.saveMessage,
               !saveMessage.hasPrefix("Settings saved.") {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(saveMessage == "Settings have been saved." ? Color.white : Color.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            saveButton
        }
        .padding(.horizontal, 13)
        .frame(height: 53)
        .background(Color(red: 35 / 255, green: 40 / 255, blue: 42 / 255))
    }

    private var saveButton: some View {
        Button(action: saveSettings) {
            ZStack {
                saveButtonFace(for: .idle) {
                    Text("Save")
                }

                saveButtonFace(for: .saving) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Saving...")
                }

                saveButtonFace(for: .success) {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                    Text("Saved")
                }

                saveButtonFace(for: .failure) {
                    Image(systemName: "exclamationmark")
                        .fontWeight(.semibold)
                    Text("Retry")
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 136, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(saveButtonBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(saveButtonState == .saving)
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityLabel(saveButtonState.accessibilityLabel)
    }

    private var saveButtonBackground: Color {
        switch saveButtonState {
        case .failure:
            return Color(red: 112 / 255, green: 48 / 255, blue: 48 / 255)
        case .idle, .saving, .success:
            return Color(red: 60 / 255, green: 62 / 255, blue: 64 / 255)
        }
    }

    private func saveButtonFace<Content: View>(
        for state: SaveButtonState,
        @ViewBuilder content: () -> Content
    ) -> some View {
        animatedButtonFace(isVisible: saveButtonState == state, content: content)
            .animation(saveAnimation, value: saveButtonState)
    }

    private func animatedButtonFace<Content: View>(
        isVisible: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: reduceMotion || isVisible ? 0 : 3)
        .blur(radius: reduceMotion || isVisible ? 0 : 2)
        .accessibilityHidden(!isVisible)
    }

    private var saveAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)
    }

    private func saveSettings() {
        guard saveButtonState != .saving else { return }

        saveResetTask?.cancel()
        settings.clearSaveMessage()

        withAnimation(saveAnimation) {
            saveButtonState = .saving
        }

        let saveResult = settings.save()
        saveResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            withAnimation(saveAnimation) {
                saveButtonState = saveResult.didSave ? .success : .failure
            }
            settings.showSaveMessage(for: saveResult)

            try? await Task.sleep(for: .milliseconds(saveResult.didSave ? 3000 : 3000))
            guard !Task.isCancelled else { return }

            withAnimation(saveAnimation) {
                saveButtonState = .idle
            }
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ShellPathResolver.expanded(settings.workingDirectory))
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingDirectory = url.path
        }
    }

    private func chooseAllowedDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Please select the directories to automatically allow when starting local-mcp."
        panel.directoryURL = URL(fileURLWithPath: ShellPathResolver.expanded(settings.workingDirectory))
        if panel.runModal() == .OK {
            settings.addAllowedDirectories(panel.urls.map(\.path))
        }
    }


    private enum UpdateButtonState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case downloading
        case installing
        case failure
    }

    private enum SaveButtonState {
        case idle
        case saving
        case success
        case failure

        var accessibilityLabel: String {
            switch self {
            case .idle:
                return "Save settings."
            case .saving:
                return "Saving settings."
            case .success:
                return "Saved settings."
            case .failure:
                return "Failed to save settings. Retry."
            }
        }
    }
}
