//
//  MenuBarMenuView.swift
//

import Darwin
import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            openSettingsAndBringToFront()
        }

        Divider()

        Button("Quit Shot2Photos") {
            exit(EXIT_SUCCESS)
        }
    }

    private func openSettingsAndBringToFront() {
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

#Preview("Menu Bar Menu") {
    MenuBarMenuView()
}
