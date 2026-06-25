import AppKit
import OKDiskCore
import SwiftUI

struct OKDiskMenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openDashboard()
            } label: {
                Label("Open Dashboard", systemImage: "rectangle.grid.2x2")
            }
            .keyboardShortcut("d")
            .accessibilityIdentifier(OKDiskAX.menuDashboard)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task { await model.refresh() }
    }

    private func openDashboard() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let dashboardWindows = NSApplication.shared.windows.filter { window in
            window.title == OKDiskWindow.dashboardTitle || window.identifier?.rawValue == OKDiskWindow.dashboard.rawValue
        }

        if let existingWindow = dashboardWindows.first {
            dashboardWindows.dropFirst().forEach { $0.close() }
            existingWindow.deminiaturize(nil)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: OKDiskWindow.dashboard.rawValue)
    }
}

enum DashboardSection: String, Hashable {
    case dashboard
    case destinations
    case folders
    case restore
}

struct DashboardWindow: View {
    @ObservedObject var model: AppModel
    @State private var selectedSection: DashboardSection = .dashboard

    var body: some View {
        TabView(selection: $selectedSection) {
            DashboardOverviewPane(model: model)
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
                .tag(DashboardSection.dashboard)

            DestinationsWindow(model: model, selectedSection: $selectedSection)
                .tabItem { Label("Destinations", systemImage: "externaldrive") }
                .tag(DashboardSection.destinations)

            FoldersWindow(model: model, selectedSection: $selectedSection)
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(DashboardSection.folders)

            RestoreWindow(model: model)
                .tabItem { Label("Restore", systemImage: "arrow.down.doc") }
                .tag(DashboardSection.restore)
        }
        .accessibilityIdentifier(OKDiskAX.dashboardTabs)
        .toolbar { RefreshToolbar(model: model) }
        .task { await model.refresh() }
    }
}

struct DashboardOverviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WindowHeader(
                    title: "OKDisk",
                    subtitle: "Manual backup to ordinary destination folders"
                )

                SectionCard("Status", systemImage: "waveform.path.ecg") {
                    HStack(spacing: 12) {
                        SummaryMetric(title: "Destinations", value: "\(model.status.onlineDestinationCount)/\(model.status.destinationCount)", caption: "online")
                        SummaryMetric(title: "Folders", value: "\(model.status.folderCount)", caption: "configured")
                        SummaryMetric(title: "Conflicts", value: "\(model.conflicts.count)", caption: model.conflicts.isEmpty ? "none" : "attention")
                    }

                    HStack {
                        StatusBadge(text: model.statusLabel, color: statusColor(model.status.state, hasConflicts: !model.conflicts.isEmpty))
                        Text(model.detail)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .accessibilityIdentifier(OKDiskAX.statusLabel)
                }

                NotificationStrip(model: model)

                SectionCard("Quick Actions", systemImage: "bolt") {
                    HStack {
                        Button {
                            Task { await model.backupAll() }
                        } label: {
                            Label("Backup Now", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRunDataOperation)
                        .accessibilityIdentifier(OKDiskAX.menuBackupNow)

                        Button {
                            Task { await model.verify(deep: false) }
                        } label: {
                            Label("Quick Verify", systemImage: "checkmark.seal")
                        }
                        .disabled(!model.canMutate)

                        Button {
                            Task { await model.verify(deep: true) }
                        } label: {
                            Label("Deep Verify", systemImage: "checkmark.seal.fill")
                        }
                        .disabled(!model.canMutate)

                        Spacer()
                    }
                }

                if !model.conflicts.isEmpty {
                    SectionCard("Destination Conflicts", systemImage: "exclamationmark.triangle") {
                        ConflictList(conflicts: model.conflicts)
                        Button {
                            Task { await model.reconcileConflicts() }
                        } label: {
                            Label("Update Destinations to Latest", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canReconcile)
                        .accessibilityIdentifier(OKDiskAX.reconcileButton)
                    }
                }

                SectionCard("Recent Activity", systemImage: "clock.arrow.circlepath") {
                    if model.recentOperations.isEmpty {
                        EmptyState(title: "No GUI-triggered operations yet", message: "Run backup, verify, restore, prune, or reconcile from the app to see summaries here.")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.recentOperations.prefix(3), id: \.id) { operation in
                                OperationRow(operation: operation)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .dashboardPaneLayout()
    }
}

struct DestinationsWindow: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSection: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowHeader(
                title: "Destinations",
                subtitle: "Attach ordinary folders or external volumes as OKDisk backup destinations."
            )

            HStack {
                Button {
                    chooseAndAttachDestination()
                } label: {
                    Label("Add Destination…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
                .accessibilityIdentifier(OKDiskAX.addDestination)

                Button("Refresh") { Task { await model.refresh() } }
                    .accessibilityIdentifier(OKDiskAX.refreshButton)

                Spacer()
            }

            NotificationStrip(model: model) {
                selectedSection = .dashboard
            }

            if model.destinations.isEmpty {
                EmptyState(title: "No destinations attached", message: "Add a writable folder to initialize it as an OKDisk destination.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.destinations, id: \.rootPath) { destination in
                            DestinationRow(model: model, destination: destination)
                        }
                    }
                    .accessibilityIdentifier(OKDiskAX.destinationList)
                }
            }
        }
        .dashboardPaneLayout()
    }

    private func chooseAndAttachDestination() {
        guard let path = DirectoryPicker.pickDirectory(
            title: "Choose Destination Folder",
            message: "OKDisk will create metadata and data folders inside the selected directory.",
            prompt: "Add Destination"
        ) else { return }
        Task { await model.attachDestination(path: path) }
    }
}

struct DestinationRow: View {
    @ObservedObject var model: AppModel
    let destination: DestinationStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    StatusBadge(text: destination.state.rawValue.capitalized, color: destinationColor(destination.state))
                    if destination.isWritable {
                        StatusBadge(text: "Writable", color: .green)
                    } else {
                        StatusBadge(text: "Read-only", color: .orange)
                    }
                    Spacer()
                }

                PathText(destination.rootPath)

                if let canonicalRootPath = destination.canonicalRootPath, canonicalRootPath != destination.rootPath {
                    LabeledText(label: "Canonical", value: canonicalRootPath)
                }
                LabeledText(label: "Store ID", value: destination.storeID ?? "Unavailable")
                LabeledText(label: "Latest Sync Seq", value: "\(destination.latestSyncRunSeq)")
                if let message = destination.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .trailing, spacing: 8) {
                Button(role: .destructive) {
                    Task { await model.pruneDestination(destination) }
                } label: {
                    Label("Prune", systemImage: "trash")
                }
                .disabled(!model.canRunDataOperation || destination.state == .offline)
                .accessibilityIdentifier(OKDiskAX.pruneDestination)

                Button(role: .destructive) {
                    Task { await model.removeDestination(destination) }
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .disabled(!model.canMutate)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("okdisk.destination.row")
    }
}

struct FoldersWindow: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSection: DashboardSection
    @State private var showingAddFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowHeader(
                title: "Folders",
                subtitle: "Manage source folders and replica counts stored in destination metadata."
            )

            HStack {
                Button {
                    showingAddFolder = true
                } label: {
                    Label("Add Source Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunDataOperation)
                .accessibilityIdentifier(OKDiskAX.addFolder)

                Button("Refresh") { Task { await model.refresh() } }
                    .accessibilityIdentifier(OKDiskAX.refreshButton)

                Spacer()
            }

            NotificationStrip(model: model) {
                selectedSection = .dashboard
            }

            if model.folders.isEmpty {
                EmptyState(title: "No source folders configured", message: "Add a source folder after attaching enough destinations for its replica count.")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.folders, id: \.folderID) { folder in
                            FolderRow(model: model, folder: folder)
                                .id(folder.folderID + "-\(folder.replicaCount)")
                        }
                    }
                    .accessibilityIdentifier(OKDiskAX.folderList)
                }
            }
        }
        .dashboardPaneLayout()
        .sheet(isPresented: $showingAddFolder) {
            AddFolderSheet(model: model)
        }
    }
}

struct FolderRow: View {
    @ObservedObject var model: AppModel
    let folder: FolderConfig
    @State private var replicaCount: Int

    init(model: AppModel, folder: FolderConfig) {
        self.model = model
        self.folder = folder
        _replicaCount = State(initialValue: folder.replicaCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    CopyableHashBadge(hashID: folder.folderID)
                    CopyableTruncatedPath(path: folder.sourcePath)
                        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                }
                if !folder.excludedPatterns.isEmpty {
                    LabeledText(label: "Excludes", value: folder.excludedPatterns.joined(separator: ", "))
                }
            }

            Divider()

            HStack {
                HStack(spacing: 8) {
                    Stepper("Replica count: \(replicaCount)", value: $replicaCount, in: 1...max(1, model.destinations.count))
                    Button("Save Replicas") {
                        Task { await model.updateFolderReplica(folderID: folder.folderID, replicaCount: replicaCount) }
                    }
                    .disabled(!model.canRunDataOperation || replicaCount == folder.replicaCount)
                }

                Spacer()

                Button {
                    Task { await model.backup(folderID: folder.folderID) }
                } label: {
                    Label("Backup", systemImage: "arrow.up.circle")
                }
                .disabled(!model.canRunDataOperation)

                Button {
                    Task { await model.verify(deep: false, folderID: folder.folderID) }
                } label: {
                    Label("Verify", systemImage: "checkmark.seal")
                }
                .disabled(!model.canMutate)

                Button {
                    Task { await model.verify(deep: true, folderID: folder.folderID) }
                } label: {
                    Label("Deep Verify", systemImage: "checkmark.seal.fill")
                }
                .disabled(!model.canMutate)

                Button(role: .destructive) {
                    Task { await model.removeFolder(folder) }
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .disabled(!model.canRunDataOperation)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("okdisk.folder.row")
    }
}

struct AddFolderSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourcePath = ""
    @State private var replicaCount = 1
    @State private var excludedPatternsText = ".DS_Store\n.okdisk/**"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowHeader(
                title: "Add Source Folder",
                subtitle: "Choose a folder and how many destination replicas OKDisk should maintain."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Folder")
                    .font(.headline)
                HStack {
                    TextField("/Users/me/Documents", text: $sourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        if let path = DirectoryPicker.pickDirectory(title: "Choose Source Folder", prompt: "Choose") {
                            sourcePath = path
                        }
                    }
                }
            }

            Stepper("Replica count: \(replicaCount)", value: $replicaCount, in: 1...max(1, model.destinations.count))

            VStack(alignment: .leading, spacing: 8) {
                Text("Excluded Patterns")
                    .font(.headline)
                Text("One pattern per line. Defaults skip Finder metadata and OKDisk internals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $excludedPatternsText)
                    .frame(height: 90)
                    .font(.system(.body, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            }

            NotificationStrip(model: model)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Folder") {
                    Task {
                        let ok = await model.addFolder(
                            path: sourcePath,
                            replicaCount: replicaCount,
                            excludedPatterns: excludedPatterns
                        )
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunDataOperation || sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(OKDiskAX.addFolder)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var excludedPatterns: [String] {
        excludedPatternsText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct RestoreWindow: View {
    @ObservedObject var model: AppModel
    @State private var selectedFolderID = ""
    @State private var scopeRawValue = RestoreScope.fullFolder.rawValue
    @State private var relativePath = ""
    @State private var destinationPath = ""
    @State private var overwriteConfirmed = false
    @State private var deepVerify = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowHeader(
                title: "Restore",
                subtitle: "Restore a full folder, subfolder, or single file to a chosen output directory."
            )

            Form {
                Picker("Source Folder", selection: $selectedFolderID) {
                    Text("Choose folder").tag("")
                    ForEach(model.folders, id: \.folderID) { folder in
                        Text(folder.sourcePath).tag(folder.folderID)
                    }
                }
                .accessibilityIdentifier("okdisk.restore.folderPicker")

                Picker("Scope", selection: $scopeRawValue) {
                    Text("Full Folder").tag(RestoreScope.fullFolder.rawValue)
                    Text("Subfolder").tag(RestoreScope.subfolder.rawValue)
                    Text("Single File").tag(RestoreScope.singleFile.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("okdisk.restore.scopePicker")

                TextField("Relative path inside the backed-up folder", text: $relativePath)
                    .disabled(scope == .fullFolder)
                    .accessibilityIdentifier("okdisk.restore.relativePath")

                HStack {
                    TextField("Restore destination folder", text: $destinationPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        if let path = DirectoryPicker.pickDirectory(title: "Choose Restore Destination", prompt: "Choose") {
                            destinationPath = path
                        }
                    }
                }
                .accessibilityIdentifier("okdisk.restore.destination")

                Toggle("Allow overwrite if the generated output folder already exists", isOn: $overwriteConfirmed)
                Toggle("Deep verify while restoring", isOn: $deepVerify)
            }

            NotificationStrip(model: model)

            HStack {
                Button {
                    Task {
                        await model.restore(
                            folderID: selectedFolderID,
                            destinationPath: destinationPath,
                            scope: scope,
                            relativePath: relativePath,
                            overwriteConfirmed: overwriteConfirmed,
                            deepVerify: deepVerify
                        )
                    }
                } label: {
                    Label("Run Restore", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunDataOperation || selectedFolderID.isEmpty || destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(OKDiskAX.restoreRun)

                Spacer()
            }
        }
        .dashboardPaneLayout()
        .onAppear { ensureFolderSelection(model.folders) }
        .onChange(of: model.folders) { folders in
            ensureFolderSelection(folders)
        }
    }

    private var scope: RestoreScope {
        RestoreScope(rawValue: scopeRawValue) ?? .fullFolder
    }

    private func ensureFolderSelection(_ folders: [FolderConfig]) {
        guard selectedFolderID.isEmpty || !folders.contains(where: { $0.folderID == selectedFolderID }) else { return }
        selectedFolderID = folders.first?.folderID ?? ""
    }
}

struct RefreshToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .accessibilityIdentifier(OKDiskAX.refreshButton)
        }
    }
}

private extension View {
    func dashboardPaneLayout() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WindowHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NotificationStrip: View {
    @ObservedObject var model: AppModel
    var onViewActivity: (() -> Void)? = nil

    private var hasIssues: Bool {
        guard let latest = model.recentOperations.first else { return false }
        if let issues = latest.summary?.verificationIssues, issues > 0 { return true }
        if latest.state == .failed { return true }
        if let msg = latest.errorMessage, !msg.isEmpty { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.lastMessage {
                HStack(spacing: 4) {
                    Label(message, systemImage: hasIssues ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(hasIssues ? .orange : .green)
                        .lineLimit(3)
                    if hasIssues, let onViewActivity {
                        Button("View Activity") { onViewActivity() }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
            }
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

struct PathText: View {
    let path: String

    init(_ path: String) {
        self.path = path
    }

    var body: some View {
        Text(path)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

struct CopyableTruncatedPath: View {
    let path: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(path)
            showCopiedFeedback()
        } label: {
            GeometryReader { proxy in
                Text(shortenedPath(for: proxy.size.width))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(copied ? "Copied full folder path" : "Copy full folder path")
        .accessibilityLabel("Folder path \(path)")
        .accessibilityHint(copied ? "Copied full folder path" : "Click to copy full folder path")
    }

    private func shortenedPath(for width: CGFloat) -> String {
        guard width.isFinite, width > 0 else { return path }
        let maxCharacters = max(12, Int(width / 7.3))
        guard path.count > maxCharacters else { return path }
        guard maxCharacters > 3 else { return "…" }

        let visibleCharacters = maxCharacters - 1
        let prefixCount = max(4, visibleCharacters / 2)
        let suffixCount = max(4, visibleCharacters - prefixCount)

        guard prefixCount + suffixCount + 1 < path.count else { return path }
        return String(path.prefix(prefixCount)) + "…" + String(path.suffix(suffixCount))
    }

    private func showCopiedFeedback() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copied = false
        }
    }
}

struct CopyableHashBadge: View {
    let hashID: String
    @State private var copied = false

    private var shortHash: String {
        String(hashID.suffix(6))
    }

    var body: some View {
        Button {
            copyToClipboard(hashID)
            showCopiedFeedback()
        } label: {
            Text(shortHash)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.18))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(copied ? "Copied full folder ID" : "Copy full folder ID")
        .accessibilityLabel("Folder ID \(hashID)")
        .accessibilityHint(copied ? "Copied full folder ID" : "Click to copy full folder ID")
    }

    private func showCopiedFeedback() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copied = false
        }
    }
}

private func copyToClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

struct LabeledText: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ConflictList: View {
    let conflicts: [DestinationStateConflict]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(conflicts, id: \.rootPath) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusBadge(text: conflict.state.rawValue.capitalized, color: destinationColor(conflict.state))
                        Text("Seq \(conflict.latestSyncRunSeq)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    PathText(conflict.rootPath)
                    Text(conflict.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let storeID = conflict.storeID {
                        LabeledText(label: "Store ID", value: storeID)
                    }
                    if let reference = conflict.referenceStoreID {
                        LabeledText(label: "Reference", value: reference)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct OperationRow: View {
    let operation: OperationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                StatusBadge(text: operation.kind.rawValue.capitalized, color: .blue)
                StatusBadge(text: operation.state.rawValue.capitalized, color: operationColor(operation.state))
                Spacer()
                Text(operation.startedAtUTC)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorMessage = operation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let summary = operation.summary {
                OperationSummaryLine(summary: summary)
            }

            if let report = operation.verifyReport {
                if report.issues.isEmpty {
                    Text("Checked \(report.checkedFolders) folders, \(report.checkedFiles) files — all healthy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup {
                        let grouped = Dictionary(grouping: report.issues, by: { $0.sourcePath ?? "Destination Issues" })
                        let sortedKeys = grouped.keys.sorted { a, b in
                            if a == "Destination Issues" { return false }
                            if b == "Destination Issues" { return true }
                            return a < b
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sortedKeys, id: \.self) { sourcePath in
                                let groupIssues = grouped[sourcePath] ?? []
                                let maxDisplay = 100
                                let displayed = Array(groupIssues.prefix(maxDisplay))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(sourcePath)
                                        .font(.caption.bold())
                                        .foregroundStyle(sourcePath == "Destination Issues" ? .orange : .primary)
                                        .textSelection(.enabled)
                                    ForEach(Array(displayed.enumerated()), id: \.offset) { _, issue in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: issueIcon(for: issue.kind))
                                                .foregroundStyle(issueColor(for: issue.kind))
                                                .frame(width: 14)
                                                .font(.caption)
                                            VStack(alignment: .leading, spacing: 2) {
                                                if let rel = issue.relativePath {
                                                    Text(rel)
                                                        .font(.caption)
                                                        .textSelection(.enabled)
                                                    Text(issue.message)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                } else {
                                                    Text(issue.message)
                                                        .font(.caption)
                                                        .textSelection(.enabled)
                                                }
                                                if let dest = issue.destinationRoot {
                                                    Text(dest)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                            }
                                            Spacer()
                                            StatusBadge(text: issue.kind, color: issueColor(for: issue.kind))
                                        }
                                    }
                                    if groupIssues.count > maxDisplay {
                                        Text("Showing \(maxDisplay) of \(groupIssues.count) issues")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("\(report.issues.count) issues in \(Set(report.issues.map { $0.sourcePath ?? "Destination Issues" }).count) groups", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let completedAtUTC = operation.completedAtUTC {
                LabeledText(label: "Completed UTC", value: completedAtUTC)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct OperationSummaryLine: View {
    let summary: OperationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = summary.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if summary.filesMirrored > 0 { Text("Mirrored: \(summary.filesMirrored)") }
                if summary.filesDeleted > 0 { Text("Deleted: \(summary.filesDeleted)") }
                if summary.filesRestored > 0 { Text("Restored: \(summary.filesRestored)") }
                if summary.verificationIssues > 0 { Text("Issues: \(summary.verificationIssues)") }
                if summary.repairedFiles > 0 { Text("Repaired: \(summary.repairedFiles)") }
                if summary.reconciledDestinations > 0 { Text("Reconciled: \(summary.reconciledDestinations)") }
                if summary.prunedTrees > 0 { Text("Pruned trees: \(summary.prunedTrees)") }
                if summary.bytesMirrored > 0 { Text(ByteCountFormatter.string(fromByteCount: summary.bytesMirrored, countStyle: .file)) }
                if summary.bytesRestored > 0 { Text(ByteCountFormatter.string(fromByteCount: summary.bytesRestored, countStyle: .file)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let outputPath = summary.outputPath {
                HStack {
                    PathText(outputPath)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
                    }
                }
            }
        }
    }
}

private func statusColor(_ state: String, hasConflicts: Bool) -> Color {
    if hasConflicts { return .orange }
    switch state {
    case "idle": return .green
    case "operation_running": return .blue
    case "starting": return .secondary
    default: return .orange
    }
}

private func destinationColor(_ state: DestinationState) -> Color {
    switch state {
    case .healthy: return .green
    case .offline: return .secondary
    case .stale: return .orange
    case .diverged: return .red
    case .corrupted: return .red
    }
}

private func operationColor(_ state: OperationState) -> Color {
    switch state {
    case .running: return .blue
    case .succeeded: return .green
    case .failed: return .red
    }
}

private func issueIcon(for kind: String) -> String {
    switch kind {
    case "missing", "missing_tree": return "doc.questionmark"
    case "corrupt": return "exclamationmark.octagon"
    case "stale": return "clock.badge.exclamationmark"
    case "offline": return "wifi.slash"
    case "conflict": return "arrow.triangle.2.circlepath"
    case "replica_count": return "person.2.slash"
    default: return "exclamationmark.triangle"
    }
}

private func issueColor(for kind: String) -> Color {
    switch kind {
    case "missing", "missing_tree": return .orange
    case "corrupt": return .red
    case "stale": return .yellow
    case "offline": return .gray
    case "conflict": return .purple
    case "replica_count": return .blue
    default: return .orange
    }
}
