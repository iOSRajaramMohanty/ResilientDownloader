//
//  ResilientDownloaderTests.swift
//  ResilientDownloader
//
//  Basic tests for ResilientDownloader
//

import XCTest
@testable import ResilientDownloader

final class ResilientDownloaderTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = DownloadConfiguration.default
        
        XCTAssertEqual(config.chunkSize, 2 * 1024 * 1024)
        XCTAssertEqual(config.maxConcurrentChunks, 4)
        XCTAssertEqual(config.maxRetries, 10)
        XCTAssertEqual(config.initialRetryDelay, 1.0)
    }
    
    func testAggressiveConfiguration() {
        let config = DownloadConfiguration.aggressive
        
        XCTAssertEqual(config.chunkSize, 256 * 1024)
        XCTAssertEqual(config.maxConcurrentChunks, 2)
        XCTAssertEqual(config.maxRetries, 20)
    }
    
    // MARK: - ChunkRange Tests
    
    func testChunkRangeLength() {
        let range = ChunkRange(start: 0, end: 999)
        XCTAssertEqual(range.length, 1000)
    }
    
    func testChunkRangeHeader() {
        let range = ChunkRange(start: 1000, end: 1999)
        XCTAssertEqual(range.rangeHeaderValue, "bytes=1000-1999")
    }
    
    // MARK: - Checksum Tests
    
    func testSHA256Checksum() {
        let data = "Hello, World!".data(using: .utf8)!
        let checksum = Checksum.sha256(data: data)
        
        XCTAssertEqual(checksum, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
    }
    
    // MARK: - RetryEngine Tests
    
    func testRetryDelay() async {
        let engine = RetryEngine(initialDelay: 1.0, maxDelay: 60.0, maxRetries: 5)
        
        let delay1 = await engine.delay(forAttempt: 1)
        XCTAssertGreaterThan(delay1, 0)
        XCTAssertLessThanOrEqual(delay1, 1.5)
        
        let delay3 = await engine.delay(forAttempt: 3)
        XCTAssertGreaterThan(delay3, delay1)
    }
    
    func testShouldRetry() async {
        let engine = RetryEngine(maxRetries: 3)
        
        let should1 = await engine.shouldRetry(attempt: 1)
        XCTAssertTrue(should1)
        
        let should4 = await engine.shouldRetry(attempt: 4)
        XCTAssertFalse(should4)
    }
    
    // MARK: - DownloadState Tests
    
    func testDownloadStateProgress() {
        var state = DownloadState(
            url: URL(string: "https://example.com/file.bin")!,
            destination: URL(fileURLWithPath: "/tmp/file.bin"),
            totalBytes: 1000,
            downloadedBytes: 500
        )
        
        XCTAssertEqual(state.progress, 0.5)
        
        state.downloadedBytes = 1000
        XCTAssertEqual(state.progress, 1.0)
    }
    
    func testDownloadStateCanResume() {
        var state = DownloadState(
            url: URL(string: "https://example.com/file.bin")!,
            destination: URL(fileURLWithPath: "/tmp/file.bin"),
            totalBytes: 1000,
            status: .paused
        )
        
        XCTAssertTrue(state.canResume)
        
        state.status = .completed
        XCTAssertFalse(state.canResume)
        
        state.status = .failed
        XCTAssertTrue(state.canResume)
    }
    
    // MARK: - Network Quality Tests
    
    func testNetworkAdapterIsAccessible() {
        let adapter = NetworkAdapter.shared
        
        // Should not crash
        _ = adapter.connectionType
        _ = adapter.isConnected
        _ = adapter.estimatedQuality
    }
    
    // MARK: - Download Error Tests
    
    func testDownloadErrorDescriptions() {
        XCTAssertNotNil(DownloadError.invalidURL.errorDescription)
        XCTAssertNotNil(DownloadError.serverNotSupportRangeRequests.errorDescription)
        XCTAssertNotNil(DownloadError.httpError(statusCode: 404, message: "Not Found").errorDescription)
        XCTAssertNotNil(DownloadError.checksumMismatch(expected: "abc", actual: "xyz").errorDescription)
    }
}
