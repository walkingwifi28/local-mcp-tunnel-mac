import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: CLIController
    @State private var selectedLogSource: CLIController.LogSource = .tunnel
    @State private var tunnelInput = ""
    @State private var localMCPInput = ""

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                tunnelCard
                localMCPCard
            }
            logCard
        }
        .padding(18)
        .frame(minWidth: 880, minHeight: 700)
        .alert("Error", isPresented: Binding(
            get: { controller.presentedError != nil },
            set: { if !$0 { controller.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { controller.presentedError = nil }
        } message: {
            Text(controller.presentedError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Local MCP Tunnel")
                    .font(.title2.bold())
            }
            Spacer()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private var tunnelCard: some View {
        GroupBox("Tunnel Client") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow(controller.tunnelState)
                LabeledContent("Profile :", value: settings.profileName.isEmpty ? "None" : settings.profileName)
                LabeledContent("Tunnel ID :", value: settings.tunnelID.isEmpty ? "None" : settings.tunnelID)
                HStack {
                    Button("Init") {
                        settings.save()
                        controller.initializeTunnel(using: settings.configuration)
                    }
                    .disabled(controller.tunnelState.isBusy || controller.tunnelState.isRunning)

                    if controller.canStopTunnel {
                        Button("Stop", role: .destructive) { controller.stopTunnel() }
                    } else {
                        Button("Run") {
                            settings.save()
                            controller.startTunnel(using: settings.configuration)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.tunnelState.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var localMCPCard: some View {
        GroupBox("local-mcp") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow(controller.localMCPState)
                LabeledContent("Session :", value: settings.sessionID.isEmpty ? "None" : settings.sessionID)
                LabeledContent("Working Dir :", value: settings.workingDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    if controller.localMCPState.isRunning {
                        Button("Stop", role: .destructive) { controller.stopLocalMCP() }
                    } else {
                        Button("Start") {
                            settings.save()
                            controller.startLocalMCP(using: settings.configuration)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.localMCPState.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var logCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("Log")
                        .font(.headline)

                    Picker("Log Type", selection: $selectedLogSource) {
                        ForEach(CLIController.LogSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)

                    if selectedLogSource == .localMCP {
                        permissionToolbar
                    }

                    Spacer()

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedLogText, forType: .string)
                    }
                    Button("Clear") {
                        controller.clearLog(for: selectedLogSource)
                    }
                }

                LogTextView(
                    text: selectedLogText,
                    input: selectedInput,
                    isInputEnabled: controller.canSendInput(to: selectedLogSource),
                    prompt: "› ",
                    onSubmit: sendSelectedInput
                )
                .id(selectedLogSource)
                .frame(minHeight: 270)
            }
            .padding(6)
        }
    }

    private var permissionToolbar: some View {
        HStack(spacing: 8) {
            Picker("Permission Mode", selection: permissionModeSelection) {
                ForEach(PermissionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Button("Allow…") { chooseAllowedDirectory() }
            Menu("Revoke") {
                if revocableDirectories.isEmpty {
                    Text("No directories are available to revoke.")
                } else {
                    ForEach(revocableDirectories, id: \.self) { directory in
                        Button(directory) {
                            controller.sendPermission(.revoke(directory))
                        }
                        .help(directory)
                    }
                }
            }
            .menuStyle(.button)
            Button("List") { controller.sendPermission(.list) }
            Button("Status") { controller.sendPermission(.status) }
        }
        .disabled(!controller.localMCPState.isRunning)
    }

    private var permissionModeSelection: Binding<PermissionMode> {
        Binding(
            get: { controller.permissionMode },
            set: { selectPermissionMode($0) }
        )
    }

    private func selectPermissionMode(_ mode: PermissionMode) {
        guard mode != controller.permissionMode else { return }

        switch mode {
        case .ask:
            controller.sendPermission(.ask)
        case .yolo:
            controller.sendPermission(.yolo)
        }
    }

    private var selectedLogText: String {
        controller.logText(for: selectedLogSource)
    }

    private var selectedInput: Binding<String> {
        switch selectedLogSource {
        case .tunnel:
            return $tunnelInput
        case .localMCP:
            return $localMCPInput
        }
    }

    private func sendSelectedInput() {
        let input = selectedInput.wrappedValue
        guard controller.sendInput(input, to: selectedLogSource) else { return }
        selectedInput.wrappedValue = ""
    }

    private func statusRow(_ state: ProcessState) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.isRunning ? Color.green : (state.isBusy ? Color.orange : Color.secondary))
                .frame(width: 9, height: 9)
            Text(state.label)
                .font(.subheadline.weight(.medium))
            if case let .failed(message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    private var revocableDirectories: [String] {
        let workingDirectory = URL(
            fileURLWithPath: ShellPathResolver.expanded(settings.workingDirectory),
            isDirectory: true
        )
        .standardizedFileURL
        .path

        return controller.allowedDirectories
            .filter { $0 != workingDirectory }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func chooseAllowedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ShellPathResolver.expanded(settings.workingDirectory))
        if panel.runModal() == .OK, let path = panel.url?.path {
            controller.sendPermission(.allow(path))
        }
    }
}
