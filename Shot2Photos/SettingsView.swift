//
//  SettingsView.swift
//

import OSLog
import Photos
import SwiftUI
import UserNotifications

private let settingsLogger = Logger(
    subsystem: "com.rui.Shot2Photos",
    category: "Settings"
)

@MainActor
struct SettingsView: View {
    let service: ScreenshotImportService

    @Environment(\.openURL) private var openURL
    @AppStorage("removeSourceAfterImport") private var removeSourceAfterImport = false
    @State private var photoAuthorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("Import") {
                Toggle(
                    "Move originals to Trash after successful import",
                    isOn: $removeSourceAfterImport
                )
            }

            Section("Status") {
                StatusRow(
                    title: "Photos access",
                    value: photoStatusText,
                    isHealthy: photoAccessIsAvailable,
                    actionTitle: photoAuthorization == .notDetermined
                        ? "Request Photos Access"
                        : "Open System Settings",
                    action: photoAuthorization == .notDetermined
                        ? requestPhotoAccess
                        : openPhotosSettings
                )

                StatusRow(
                    title: "Notifications",
                    value: notificationStatusText,
                    isHealthy: notificationAccessIsAvailable,
                    actionTitle: "Open System Settings",
                    action: openNotificationSettings
                )

                LabeledContent("Screenshot folder") {
                    Text(service.monitoredDirectoryPath ?? "Unavailable")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Filesystem monitor") {
                    Text(service.isMonitoring ? "Running" : "Unavailable")
                        .foregroundStyle(service.isMonitoring ? Color.secondary : Color.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear {
            settingsLogger.info("SettingsView appeared")
            refreshStatus()
        }
        .task {
            service.start()
        }
    }

    private var photoAccessIsAvailable: Bool {
        photoAuthorization == .authorized || photoAuthorization == .limited
    }

    private var notificationAccessIsAvailable: Bool {
        notificationAuthorization == .authorized
            || notificationAuthorization == .provisional
    }

    private var photoStatusText: String {
        switch photoAuthorization {
        case .authorized, .limited:
            return "Allowed"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        @unknown default:
            return "Unknown"
        }
    }

    private var notificationStatusText: String {
        switch notificationAuthorization {
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        case .ephemeral:
            return "Temporary"
        @unknown default:
            return "Unknown"
        }
    }

    private func requestPhotoAccess() {
        Task {
            photoAuthorization = await service.requestPhotoLibraryAuthorization()
        }
    }

    private func refreshStatus() {
        let addOnlyStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        settingsLogger.info(
            "Photos authorization refresh: addOnly=\(String(describing: addOnlyStatus), privacy: .public), bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)"
        )

        photoAuthorization = addOnlyStatus

        Task {
            notificationAuthorization = await currentNotificationAuthorization()
        }
    }

    private func currentNotificationAuthorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func openPhotosSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Photos",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ])
    }

    private func openNotificationSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ])
    }

    private func openSystemSettings(_ strings: [String]) {
        guard let url = strings.compactMap(URL.init(string:)).first else {
            return
        }

        openURL(url)
    }
}

#Preview("Settings") {
    SettingsView(service: ScreenshotImportService())
}

private struct StatusRow: View {
    let title: String
    let value: String
    let isHealthy: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(isHealthy ? Color.green : Color.red)
            }

            if !isHealthy {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}
