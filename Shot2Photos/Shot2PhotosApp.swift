//
//  Shot2PhotosApp.swift
//

import AppKit
import OSLog
import SwiftUI

private let appLogger = Logger(
    subsystem: "com.rui.Shot2Photos",
    category: "App"
)

@main
struct Shot2PhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Shot2Photos", systemImage: "photo.on.rectangle") {
            MenuBarMenuView()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(service: appDelegate.importService)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let importService = ScreenshotImportService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLogger.info("Application did finish launching")
        importService.start()
    }
}
