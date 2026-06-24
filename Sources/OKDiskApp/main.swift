import AppKit
import OKDiskCore
import SwiftUI

@main
struct OKDiskMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("OKDisk")
                    .font(.headline)
                Text("Status: \(model.statusLabel)")
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(8)
            .task { await model.refresh() }
        } label: {
            Image(systemName: model.iconName)
                .accessibilityLabel("OKDisk Status")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var statusLabel = "Starting"
    @Published var detail = "Starting OKDisk engine"
    @Published var iconName = "externaldrive"

    private let host: EngineHost
    private var refreshTask: Task<Void, Never>?

    init() {
        let environment = Bundle.main.object(forInfoDictionaryKey: "OKDiskEnvironment") as? String
        let appEnvironment: OKDiskEnvironment = environment == "prod" ? .production : .development
        self.host = EngineHost(environment: appEnvironment)
        self.host.startXPCListener()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        host.stopXPCListener()
    }

    func refresh() async {
        let status = await host.service.getStatus()
        switch status.state {
        case "idle":
            statusLabel = "Idle"
            iconName = status.conflicts.isEmpty ? "externaldrive" : "externaldrive.badge.exclamationmark"
        case "operation_running":
            statusLabel = "Operation Running"
            iconName = "arrow.triangle.2.circlepath"
        default:
            statusLabel = "Attention Needed"
            iconName = "externaldrive.badge.exclamationmark"
        }
        detail = status.detail
    }
}
