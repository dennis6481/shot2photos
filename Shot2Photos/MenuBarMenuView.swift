//
//  MenuBarMenuView.swift
//

import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Button("Quit Shot2Photos") {
            NSApplication.shared.terminate(nil)
        }
    }
}

#Preview("Menu Bar Menu") {
    MenuBarMenuView()
}
