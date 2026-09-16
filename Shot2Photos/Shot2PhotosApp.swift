//
//  Shot2PhotosApp.swift
//

import AppKit
import SwiftUI

@main
struct Shot2PhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Shot2Photos", systemImage: "photo.on.rectangle") {
            ContentView()
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let importService = ScreenshotImportService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        importService.start()
    }
}
