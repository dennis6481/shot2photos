//
//  ContentView.swift
//

import AppKit
import SwiftUI

struct ContentView: View {
    @AppStorage("removeSourceAfterImport") private var removeSourceAfterImport = false

    var body: some View {
        Toggle("Move originals to Trash after import", isOn: $removeSourceAfterImport)

        Divider()

        Button("Quit Shot2Photos") {
            NSApplication.shared.terminate(nil)
        }
    }
}
