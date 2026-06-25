import AppKit
import SwiftUI

enum OKDiskWindow: String {
    case dashboard = "okdisk.dashboard"

    static let dashboardTitle = "OKDisk Dashboard"
}

@main
struct OKDiskMenuBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            OKDiskMenuContent(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuStatusIconName)
                if model.hasWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .accessibilityLabel("OKDisk \(model.statusLabel)")
            .accessibilityIdentifier(OKDiskAX.menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Window(OKDiskWindow.dashboardTitle, id: OKDiskWindow.dashboard.rawValue) {
            DashboardWindow(model: model)
        }
        .defaultSize(width: 980, height: 680)
    }
}
