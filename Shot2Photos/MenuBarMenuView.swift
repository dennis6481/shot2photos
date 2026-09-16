//
//  MenuBarMenuView.swift
//

import Darwin
import SwiftUI

struct MenuBarMenuView: View {
    var body: some View {
        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit Shot2Photos") {
            exit(EXIT_SUCCESS)
        }
    }
}

#Preview("Menu Bar Menu") {
    MenuBarMenuView()
}
