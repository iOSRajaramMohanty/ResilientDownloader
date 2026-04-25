//
//  DownloadState.swift
//  ResilientDownloader
//
//  Persistent state for resumable downloads
//

import Foundation

/// Overall status of a download
public enum DownloadStatus: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// Complete state of a download for persistence and resume
public struct DownloadState: Codable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let destination: URL
    public let totalBytes: Int64
    public var downloadedBytes: Int64
    public var chunks: [ChunkState]
    public var status: DownloadStatus
    public var lastError: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var expectedChecksum: String?
    
    public init(
        id: String = UUID().uuidString,
        url: URL,
        destination: URL,
        totalBytes: Int64,
        downloadedBytes: Int64 = 0,
        chunks: [ChunkState] = [],
        status: DownloadStatus = .pending,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expectedChecksum: String? = nil
    ) {
        self.id = id
        self.url = url
        self.destination = destination
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.chunks = chunks
        self.status = status
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expectedChecksum = expectedChecksum
    }
    
    /// Overall progress (0.0 to 1.0)
    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }
    
    /// Number of completed chunks
    public var completedChunks: Int {
        chunks.filter { $0.status == .completed }.count
    }
    
    /// Number of pending chunks
    public var pendingChunks: Int {
        chunks.filter { $0.status == .pending || $0.status == .failed }.count
    }
    
    /// Check if download can be resumed
    public var canResume: Bool {
        status == .paused || status == .failed
    }
    
    /// Human-readable progress string
    public var progressDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: downloadedBytes)
        let total = formatter.string(fromByteCount: totalBytes)
        let percentage = Int(progress * 100)
        return "\(downloaded) / \(total) (\(percentage)%)"
    }
    
    /// Update downloaded bytes from chunks
    public mutating func recalculateProgress() {
        downloadedBytes = chunks.reduce(0) { $0 + $1.downloadedBytes }
        updatedAt = Date()
    }
}

/// Published download progress for UI binding
public struct DownloadProgress: Sendable {
    public let taskId: String
    public let progress: Double
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double
    public let estimatedTimeRemaining: TimeInterval?
    
    public init(
        taskId: String,
        progress: Double,
        downloadedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double = 0,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.taskId = taskId
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
    
    public var speedDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
    
    public var etaDescription: String? {
        guard let eta = estimatedTimeRemaining, eta.isFinite && eta > 0 else { return nil }
        
        let minutes = Int(eta) / 60
        let seconds = Int(eta) % 60
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s remaining"
        } else {
            return "\(seconds)s remaining"
        }
    }
}
