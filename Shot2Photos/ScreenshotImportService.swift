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
    private enum NotificationThumbnailError: LocalizedError {
        case sourceImageUnreadable
        case thumbnailCreationFailed
        case cachesDirectoryUnavailable
        case cacheDirectoryCreationFailed(domain: String, code: Int)
        case destinationCreationFailed
        case thumbnailFinalizeFailed

        var errorDescription: String? {
            switch self {
            case .sourceImageUnreadable:
                return "The source image could not be read by ImageIO."
            case .thumbnailCreationFailed:
                return "ImageIO could not create a thumbnail."
            case .cachesDirectoryUnavailable:
                return "The user caches directory is unavailable."
            case let .cacheDirectoryCreationFailed(domain, code):
                return "The notification thumbnail directory could not be created (domain=\(domain), code=\(code))."
            case .destinationCreationFailed:
                return "ImageIO could not create the PNG destination."
            case .thumbnailFinalizeFailed:
                return "ImageIO could not finalize the PNG thumbnail."
            }
        }
    }

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
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let nsError = error as NSError
            NSLog(
                "Shot2Photos: Unable to enumerate screenshot directory (domain=%@, code=%ld)",
                nsError.domain,
                nsError.code
            )
            return []
        }

        return Set(urls.compactMap { url in
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                let nsError = error as NSError
                NSLog(
                    "Shot2Photos: Unable to read screenshot entry metadata (domain=%@, code=%ld)",
                    nsError.domain,
                    nsError.code
                )
                return nil
            }

            guard values.isDirectory != true else {
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
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let nsError = error as NSError
            NSLog(
                "Shot2Photos: Unable to scan screenshot directory (domain=%@, code=%ld)",
                nsError.domain,
                nsError.code
            )
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

        let attachmentURL: URL?
        do {
            attachmentURL = try makeNotificationThumbnail(from: url)
        } catch {
            attachmentURL = nil
        }

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
            guard fileManager.fileExists(atPath: url.path) else {
                NSLog("Shot2Photos: Screenshot file disappeared during readiness check")
                return false
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.fileSizeKey])
            } catch {
                let nsError = error as NSError
                NSLog(
                    "Shot2Photos: Unable to read screenshot file metadata (domain=%@, code=%ld)",
                    nsError.domain,
                    nsError.code
                )
                return false
            }

            guard let size = values.fileSize else {
                NSLog("Shot2Photos: Screenshot file size is unavailable")
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
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                return false
            } catch {
                let nsError = error as NSError
                NSLog(
                    "Shot2Photos: Screenshot readiness wait failed (domain=%@, code=%ld)",
                    nsError.domain,
                    nsError.code
                )
                return false
            }
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
            NSLog("Shot2Photos: Photos access was not authorized: %@", String(describing: authorization))
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }
            NSLog("Shot2Photos: Photos import succeeded")
            return true
        } catch {
            NSLog("Shot2Photos: Photos import failed: %@", error.localizedDescription)
            return false
        }
    }

    private func photoLibraryAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else {
            return status
        }

        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func makeNotificationThumbnail(from sourceURL: URL) throws -> URL {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            throw NotificationThumbnailError.sourceImageUnreadable
        }

        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
        ) else {
            throw NotificationThumbnailError.thumbnailCreationFailed
        }

        guard let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NotificationThumbnailError.cachesDirectoryUnavailable
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
                throw NotificationThumbnailError.destinationCreationFailed
            }

            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NotificationThumbnailError.thumbnailFinalizeFailed
            }
            return destinationURL
        } catch {
            if let thumbnailError = error as? NotificationThumbnailError {
                throw thumbnailError
            }

            let nsError = error as NSError
            throw NotificationThumbnailError.cacheDirectoryCreationFailed(
                domain: nsError.domain,
                code: nsError.code
            )
        }
    }

    private func sendNotification(title: String, body: String, attachmentURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let attachmentURL {
            do {
                let attachment = try UNNotificationAttachment(
                    identifier: UUID().uuidString,
                    url: attachmentURL,
                    options: [
                        UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier,
                        UNNotificationAttachmentOptionsThumbnailHiddenKey: false
                    ]
                )
                content.attachments = [attachment]
            } catch {
                // Send the notification without an attachment when the thumbnail cannot be attached.
            }
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
                // Notification delivery failures do not affect the completed import.
            }
        }
    }

    deinit {
        directoryMonitor?.cancel()
    }
}
