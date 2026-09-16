//
//  ScreenshotImportService.swift
//

import CoreServices
import Darwin
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class ScreenshotImportService {
    private let fileManager = FileManager.default
    private let notificationCenter = UNUserNotificationCenter.current()
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var initialPaths = Set<String>()
    private var processingPaths = Set<String>()
    private var processedPaths = Set<String>()
    private var isStarted = false

    var isMonitoring: Bool {
        directoryMonitor != nil
    }

    var monitoredDirectoryPath: String? {
        screenshotDirectoryURL()?.path
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        requestNotificationAuthorization()

        guard let directoryURL = screenshotDirectoryURL() else {
            NSLog("Shot2Photos: Unable to determine the screenshot directory.")
            return
        }

        initialPaths = snapshot(at: directoryURL)
        startMonitoring(directoryURL)
        NSLog("Shot2Photos: Monitoring %@", directoryURL.path)
    }

    func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
        let status = await photoLibraryAuthorization()
        NSLog(
            "Shot2Photos: Photos authorization result addOnly=%@",
            String(describing: status)
        )
        if status != .authorized && status != .limited {
            NSLog("Shot2Photos: Photos access was not authorized: %@", String(describing: status))
        }
        return status
    }

    private func screenshotDirectoryURL() -> URL? {
        if let configuredLocation = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"),
           !configuredLocation.isEmpty {
            let expandedPath = (configuredLocation as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: expandedPath).standardizedFileURL
            }
        }

        let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        return desktopURL?.standardizedFileURL
    }

    private func snapshot(at directoryURL: URL) -> Set<String> {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Set(urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory != true else {
                return nil
            }
            return url.standardizedFileURL.path
        })
    }

    private func startMonitoring(_ directoryURL: URL) {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("Shot2Photos: Unable to monitor %@", directoryURL.path)
            return
        }

        let queue = DispatchQueue(label: "com.rui.Shot2Photos.filesystem")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard self != nil, source != nil else { return }
            Task { @MainActor [weak self] in
                self?.scanForNewFiles(in: directoryURL)
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        directoryMonitor = source
        source.resume()
    }

    private func scanForNewFiles(in directoryURL: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            let path = url.standardizedFileURL.path
            guard Self.shouldProcess(
                url: url,
                initialPaths: initialPaths,
                processingPaths: processingPaths,
                processedPaths: processedPaths
            ) else {
                continue
            }

            processingPaths.insert(path)
            Task { @MainActor [weak self] in
                await self?.process(url)
            }
        }
    }

    nonisolated static func shouldProcess(
        url: URL,
        initialPaths: Set<String>,
        processingPaths: Set<String>,
        processedPaths: Set<String>
    ) -> Bool {
        let path = url.standardizedFileURL.path
        return !initialPaths.contains(path)
            && !processingPaths.contains(path)
            && !processedPaths.contains(path)
            && isSupportedImage(url)
    }

    nonisolated static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private func process(_ url: URL) async {
        let path = url.standardizedFileURL.path
        defer { processingPaths.remove(path) }

        guard await waitUntilReady(url),
              isSystemScreenshot(url) else {
            return
        }

        guard await importIntoPhotos(url) else {
            sendNotification(
                title: "Screenshot import failed",
                body: "The original screenshot was kept.",
                attachmentURL: nil
            )
            return
        }

        processedPaths.insert(path)

        let attachmentURL = makeNotificationThumbnail(from: url)
        sendNotification(
            title: "Screenshot imported",
            body: "The screenshot was added to Photos.",
            attachmentURL: attachmentURL
        )

        if UserDefaults.standard.bool(forKey: "removeSourceAfterImport") {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                NSLog("Shot2Photos: Unable to move %@ to Trash: %@", path, error.localizedDescription)
            }
        }
    }

    private func waitUntilReady(_ url: URL) async -> Bool {
        var previousSize: Int?
        var stableChecks = 0

        for _ in 0..<12 {
            guard fileManager.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else {
                return false
            }

            if size == previousSize {
                stableChecks += 1
                if stableChecks >= 2 {
                    return true
                }
            } else {
                stableChecks = 0
            }

            previousSize = size
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    private func isSystemScreenshot(_ url: URL) -> Bool {
        for _ in 0..<8 {
            guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
                  let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber else {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            return value.boolValue
        }
        return false
    }

    private func importIntoPhotos(_ url: URL) async -> Bool {
        let authorization = await photoLibraryAuthorization()
        guard authorization == .authorized || authorization == .limited else {
            return false
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }, completionHandler: { success, error in
                if let error {
                    NSLog("Shot2Photos: Photos import failed: %@", error.localizedDescription)
                }
                continuation.resume(returning: success)
            })
        }
    }

    private func photoLibraryAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined else {
            return status
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Shot2Photos: Notification authorization unavailable: %@", error.localizedDescription)
            }
        }
    }

    private func makeNotificationThumbnail(from sourceURL: URL) -> URL? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else {
            return nil
        }

        guard let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryURL = baseDirectory
            .appendingPathComponent("Shot2Photos", isDirectory: true)
            .appendingPathComponent("NotificationThumbnails", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let destinationURL = directoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }

            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return destinationURL
        } catch {
            NSLog("Shot2Photos: Unable to create notification thumbnail: %@", error.localizedDescription)
            return nil
        }
    }

    private func sendNotification(title: String, body: String, attachmentURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let attachmentURL,
           let attachment = try? UNNotificationAttachment(
            identifier: UUID().uuidString,
            url: attachmentURL
        ) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await notificationCenter.add(request)
            } catch {
                NSLog("Shot2Photos: Notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    deinit {
        directoryMonitor?.cancel()
    }
}
