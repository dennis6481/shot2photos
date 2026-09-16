//
//  Shot2PhotosTests.swift
//  Shot2PhotosTests
//
//  Created by Rui Ma on 16/09/2026.
//

import Foundation
import Testing
@testable import Shot2Photos

struct Shot2PhotosTests {
    @Test(arguments: ["png", "jpg", "jpeg", "heic", "tiff"])
    func `supported image formats are accepted`(fileExtension: String) {
        let url = URL(fileURLWithPath: "/tmp/screenshot.\(fileExtension)")

        #expect(ScreenshotImportService.isSupportedImage(url))
    }

    @Test(arguments: ["txt", "pdf", "swift", ""])
    func `non image formats are rejected`(fileExtension: String) {
        let url = URL(fileURLWithPath: "/tmp/file\(fileExtension.isEmpty ? "" : ".\(fileExtension)")")

        #expect(!ScreenshotImportService.isSupportedImage(url))
    }

    @Test func `new supported image is eligible for processing`() {
        let url = URL(fileURLWithPath: "/tmp/new-screenshot.png")

        #expect(ScreenshotImportService.shouldProcess(
            url: url,
            initialPaths: [],
            processingPaths: [],
            processedPaths: []
        ))
    }

    @Test func `initial file is ignored`() {
        let url = URL(fileURLWithPath: "/tmp/existing-screenshot.png")

        #expect(!ScreenshotImportService.shouldProcess(
            url: url,
            initialPaths: [url.path],
            processingPaths: [],
            processedPaths: []
        ))
    }

    @Test func `file already being processed is ignored`() {
        let url = URL(fileURLWithPath: "/tmp/in-flight-screenshot.png")

        #expect(!ScreenshotImportService.shouldProcess(
            url: url,
            initialPaths: [],
            processingPaths: [url.path],
            processedPaths: []
        ))
    }

    @Test func `processed file is ignored`() {
        let url = URL(fileURLWithPath: "/tmp/processed-screenshot.png")

        #expect(!ScreenshotImportService.shouldProcess(
            url: url,
            initialPaths: [],
            processingPaths: [],
            processedPaths: [url.path]
        ))
    }

    @Test @MainActor func `service starts without an active monitor`() {
        let service = ScreenshotImportService()

        #expect(!service.isMonitoring)
    }
}
