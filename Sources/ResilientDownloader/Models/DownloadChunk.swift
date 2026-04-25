//
//  DownloadChunk.swift
//  ResilientDownloader
//
//  Represents a chunk of a file being downloaded
//

import Foundation

/// Represents a byte range for a download chunk
public struct ChunkRange: Codable, Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    
    public var length: Int64 {
        end - start + 1
    }
    
    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
    
    /// HTTP Range header value for this chunk
    public var rangeHeaderValue: String {
        "bytes=\(start)-\(end)"
    }
}

/// Status of an individual chunk
public enum ChunkStatus: String, Codable, Sendable {
    case pending
    case downloading
    case completed
    case failed
}

/// State of a download chunk for persistence
public struct ChunkState: Codable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let range: ChunkRange
    public var status: ChunkStatus
    public var downloadedBytes: Int64
    public var retryCount: Int
    public var lastError: String?
    public var tempFilePath: String?
    
    public init(
        id: String = UUID().uuidString,
        index: Int,
        range: ChunkRange,
        status: ChunkStatus = .pending,
        downloadedBytes: Int64 = 0,
        retryCount: Int = 0,
        lastError: String? = nil,
        tempFilePath: String? = nil
    ) {
        self.id = id
        self.index = index
        self.range = range
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.retryCount = retryCount
        self.lastError = lastError
        self.tempFilePath = tempFilePath
    }
    
    public var isComplete: Bool {
        status == .completed && downloadedBytes == range.length
    }
    
    public var progress: Double {
        guard range.length > 0 else { return 0 }
        return Double(downloadedBytes) / Double(range.length)
    }
}

/// Result of downloading a chunk
public struct ChunkResult: Sendable {
    public let chunkIndex: Int
    public let data: Data
    public let range: ChunkRange
    
    public init(chunkIndex: Int, data: Data, range: ChunkRange) {
        self.chunkIndex = chunkIndex
        self.data = data
        self.range = range
    }
}
