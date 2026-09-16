//
//  Shot2PhotosApp.swift
//

import OSLog
import SwiftUI

private let appLogger = Logger(
    subsystem: "com.rui.Shot2Photos",
    category: "App"
)

@main
struct Shot2PhotosApp: App {
    let importService = ScreenshotImportService()

    var body: some Scene {
        MenuBarExtra("Shot2Photos", systemImage: "photo.on.rectangle") {
            MenuBarMenuView()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(service: importService)
        }
        .defaultLaunchBehavior(.presented)
    }
}
