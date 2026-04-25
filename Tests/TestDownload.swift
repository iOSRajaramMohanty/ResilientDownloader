#!/usr/bin/env swift
//
//  TestDownload.swift
//  ResilientDownloader
//
//  Manual test script for verifying download functionality
//  Run with: swift TestDownload.swift
//

import Foundation

// Test configuration
let testURL = URL(string: "https://huggingface.co/mlx-community/SmolLM-360M-Instruct-4bit/resolve/main/config.json")!
let tempDir = FileManager.default.temporaryDirectory
let destination = tempDir.appendingPathComponent("test_download_\(UUID().uuidString).json")

print("🧪 ResilientDownloader Test")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("📍 URL: \(testURL)")
print("📁 Destination: \(destination.path)")
print("")

// Simple download test using URLSession (basic verification)
print("⏳ Starting download...")

let startTime = Date()

let semaphore = DispatchSemaphore(value: 0)
var downloadError: Error?
var downloadedSize: Int64 = 0

let task = URLSession.shared.downloadTask(with: testURL) { localURL, response, error in
    if let error = error {
        downloadError = error
    } else if let localURL = localURL {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: localURL, to: destination)
            
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            downloadedSize = attrs[.size] as? Int64 ?? 0
        } catch {
            downloadError = error
        }
    }
    semaphore.signal()
}

task.resume()
semaphore.wait()

let elapsed = Date().timeIntervalSince(startTime)

if let error = downloadError {
    print("❌ Download failed: \(error.localizedDescription)")
} else {
    print("✅ Download successful!")
    print("📊 Size: \(ByteCountFormatter.string(fromByteCount: downloadedSize, countStyle: .file))")
    print("⏱️ Time: \(String(format: "%.2f", elapsed)) seconds")
    
    // Verify content
    if let content = try? String(contentsOf: destination, encoding: .utf8) {
        let preview = String(content.prefix(100))
        print("📄 Content preview: \(preview)...")
    }
    
    // Cleanup
    try? FileManager.default.removeItem(at: destination)
    print("🧹 Cleaned up temp file")
}

print("")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("Test complete!")
