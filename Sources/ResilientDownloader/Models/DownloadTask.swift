//
//  DownloadTask.swift
//  ResilientDownloader
//
//  Represents an active download task
//

import Foundation

/// Errors that can occur during download
public enum DownloadError: Error, LocalizedError, Sendable {
    case invalidURL
    case serverNotSupportRangeRequests
    case unableToGetFileSize
    case httpError(statusCode: Int, message: String?)
    case networkError(underlying: String)
    case fileSystemError(underlying: String)
    case checksumMismatch(expected: String, actual: String)
    case cancelled
    case maxRetriesExceeded(chunk: Int, lastError: String?)
    case allChunksFailed
    case invalidResponse
    case noSpaceOnDisk
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid download URL"
        case .serverNotSupportRangeRequests:
            return "Server does not support resumable downloads (Range requests)"
        case .unableToGetFileSize:
            return "Unable to determine file size from server"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message ?? "Unknown error")"
        case .networkError(let underlying):
            return "Network error: \(underlying)"
        case .fileSystemError(let underlying):
            return "File system error: \(underlying)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum verification failed. Expected: \(expected), Got: \(actual)"
        case .cancelled:
            return "Download was cancelled"
        case .maxRetriesExceeded(let chunk, let lastError):
            return "Max retries exceeded for chunk \(chunk): \(lastError ?? "Unknown error")"
        case .allChunksFailed:
            return "All download chunks failed"
        case .invalidResponse:
            return "Invalid response from server"
        case .noSpaceOnDisk:
            return "Not enough space on disk"
        case .timeout:
            return "Download timed out"
        }
    }
}

/// Handle to control an active download
public final class DownloadTaskHandle: @unchecked Sendable {
    public let id: String
    public let url: URL
    public let destination: URL
    
    internal var task: Task<URL, Error>?
    internal var isCancelled: Bool = false
    internal var isPaused: Bool = false
    
    private let lock = NSLock()
    
    public init(id: String, url: URL, destination: URL) {
        self.id = id
        self.url = url
        self.destination = destination
    }
    
    /// Cancel the download
    public func cancel() {
        lock.lock()
        isCancelled = true
        task?.cancel()
        lock.unlock()
    }
    
    /// Pause the download
    public func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }
    
    /// Check if cancelled
    public var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
    
    /// Check if paused
    public var paused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }
    
    /// Wait for download to complete
    public func waitForCompletion() async throws -> URL {
        guard let task = task else {
            throw DownloadError.cancelled
        }
        return try await task.value
    }
}

/// Information about a file to download
public struct FileInfo: Sendable {
    public let url: URL
    public let contentLength: Int64
    public let acceptsRanges: Bool
    public let etag: String?
    public let lastModified: String?
    
    public init(
        url: URL,
        contentLength: Int64,
        acceptsRanges: Bool,
        etag: String? = nil,
        lastModified: String? = nil
    ) {
        self.url = url
        self.contentLength = contentLength
        self.acceptsRanges = acceptsRanges
        self.etag = etag
        self.lastModified = lastModified
    }
}
