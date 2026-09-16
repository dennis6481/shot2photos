//
//  Shot2PhotosApp.swift
//

import OSLog
import SwiftUI

private let appLogger = Logger(
    subsystem: "com.rui.Shot2Photos",
    category: "App"
)

let shot2PhotosDisplayName = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleDisplayName"
) as? String ?? "Shot2Photos"

@main
struct Shot2PhotosApp: App {
    let importService = ScreenshotImportService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityLabel(shot2PhotosDisplayName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(service: importService)
        }
        .defaultLaunchBehavior(.presented)
    }
}
