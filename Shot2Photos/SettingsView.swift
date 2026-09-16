//
//  SettingsView.swift
//

import OSLog
import Photos
import ServiceManagement
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
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var photoAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: {
                            launchAtLoginStatus == .enabled
                                || launchAtLoginStatus == .requiresApproval
                        },
                        set: updateLaunchAtLogin
                    )
                )

                if launchAtLoginStatus == .requiresApproval {
                    Text("Approval is required in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            settingsLogger.info("SettingsView appeared")
            refreshLaunchAtLoginStatus()
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settingsLogger.error("Unable to update launch at login: \(error.localizedDescription, privacy: .public)")
        }

        refreshLaunchAtLoginStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
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
            let before = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            settingsLogger.info(
                "Photos request before=\(before.rawValue, privacy: .public), bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)"
            )

            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            let after = PHPhotoLibrary.authorizationStatus(for: .readWrite)

            settingsLogger.info(
                "Photos request result=\(result.rawValue, privacy: .public), after=\(after.rawValue, privacy: .public)"
            )

            photoAuthorization = after
        }
    }

    private func refreshStatus() {
        let readWriteStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        settingsLogger.info(
            "Photos authorization refresh: readWrite=\(String(describing: readWriteStatus), privacy: .public), bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)"
        )

        photoAuthorization = readWriteStatus

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
