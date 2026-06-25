import AppKit
import SwiftUI

enum OKDiskWindow: String {
    case dashboard = "okdisk.dashboard"
    case destinations = "okdisk.destinations"
    case folders = "okdisk.folders"
    case restore = "okdisk.restore"
    case activity = "okdisk.activity"
    case preferences = "okdisk.preferences"
}

@main
struct OKDiskMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            OKDiskMenuContent(model: model)
        } label: {
            Image(systemName: model.iconName)
                .accessibilityLabel("OKDisk Status")
                .accessibilityIdentifier(OKDiskAX.menuIcon)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("OKDisk", id: OKDiskWindow.dashboard.rawValue) {
            DashboardWindow(model: model)
        }
        .defaultSize(width: 780, height: 560)

        WindowGroup("Destinations", id: OKDiskWindow.destinations.rawValue) {
            DestinationsWindow(model: model)
        }
        .defaultSize(width: 860, height: 520)

        WindowGroup("Folders", id: OKDiskWindow.folders.rawValue) {
            FoldersWindow(model: model)
        }
        .defaultSize(width: 860, height: 560)

        WindowGroup("Restore", id: OKDiskWindow.restore.rawValue) {
            RestoreWindow(model: model)
        }
        .defaultSize(width: 760, height: 520)

        WindowGroup("Activity", id: OKDiskWindow.activity.rawValue) {
            ActivityWindow(model: model)
        }
        .defaultSize(width: 820, height: 520)

        WindowGroup("Preferences", id: OKDiskWindow.preferences.rawValue) {
            PreferencesWindow(model: model)
        }
        .defaultSize(width: 520, height: 360)
    }
}
