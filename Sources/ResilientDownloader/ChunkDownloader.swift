//
//  ChunkDownloader.swift
//  ResilientDownloader
//
//  Downloads individual chunks using HTTP Range headers
//

import Foundation

/// Downloads individual file chunks with Range header support
public actor ChunkDownloader {
    
    private let session: URLSession
    private let configuration: DownloadConfiguration
    private let retryEngine: RetryEngine
    
    public init(configuration: DownloadConfiguration = .default) {
        self.configuration = configuration
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.chunkTimeout
        sessionConfig.timeoutIntervalForResource = configuration.chunkTimeout * 2
        sessionConfig.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfig.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
        sessionConfig.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
        sessionConfig.httpMaximumConnectionsPerHost = configuration.maxConcurrentChunks
        sessionConfig.waitsForConnectivity = true
        
        self.session = URLSession(configuration: sessionConfig)
        self.retryEngine = RetryEngine(
            initialDelay: configuration.initialRetryDelay,
            maxDelay: configuration.maxRetryDelay,
            maxRetries: configuration.maxRetries
        )
    }
    
    /// Get file info (size, range support) via HEAD request
    public func getFileInfo(url: URL) async throws -> FileInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        
        let statusCode = httpResponse.statusCode
        guard statusCode >= 200 && statusCode < 400 else {
            throw DownloadError.httpError(statusCode: statusCode, message: HTTPURLResponse.localizedString(forStatusCode: statusCode))
        }
        
        var contentLength: Int64 = 0
        var acceptsRanges = false
        
        if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = contentRange.split(separator: "/").last,
           let total = Int64(totalStr) {
            contentLength = total
            acceptsRanges = true
        } else if let lengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                  let length = Int64(lengthStr) {
            contentLength = length
        }
        
        if let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges") {
            acceptsRanges = acceptRanges.lowercased() == "bytes"
        }
        
        if statusCode == 206 {
            acceptsRanges = true
        }
        
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
        
        return FileInfo(
            url: url,
            contentLength: contentLength,
            acceptsRanges: acceptsRanges,
            etag: etag,
            lastModified: lastModified
        )
    }
    
    /// Download a specific chunk with Range header
    public func downloadChunk(
        url: URL,
        range: ChunkRange,
        chunkIndex: Int,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> ChunkResult {
        
        try await retryEngine.execute { [self] in
            try await performChunkDownload(
                url: url,
                range: range,
                chunkIndex: chunkIndex,
                onProgress: onProgress
            )
        } onRetry: { attempt, error, delay in
            print("⚠️ [Chunk \(chunkIndex)] Retry \(attempt) after \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
        }
    }
    
    private func performChunkDownload(
        url: URL,
        range: ChunkRange,
        chunkIndex: Int,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> ChunkResult {
        var request = URLRequest(url: url)
        request.setValue(range.rangeHeaderValue, forHTTPHeaderField: "Range")
        request.timeoutInterval = configuration.chunkTimeout
        
        let (asyncBytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        
        let statusCode = httpResponse.statusCode
        
        guard statusCode == 206 || statusCode == 200 else {
            if isRetryableStatusCode(statusCode) {
                throw DownloadError.httpError(statusCode: statusCode, message: "Retryable HTTP error")
            }
            throw DownloadError.httpError(
                statusCode: statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }
        
        var data = Data()
        let expectedLength = range.length
        data.reserveCapacity(Int(expectedLength))
        
        var downloadedBytes: Int64 = 0
        var lastProgressUpdate: Int64 = 0
        let progressInterval: Int64 = 64 * 1024 // Update every 64KB
        
        for try await byte in asyncBytes {
            data.append(byte)
            downloadedBytes += 1
            
            if downloadedBytes - lastProgressUpdate >= progressInterval {
                onProgress?(downloadedBytes)
                lastProgressUpdate = downloadedBytes
            }
        }
        
        onProgress?(downloadedBytes)
        
        return ChunkResult(chunkIndex: chunkIndex, data: data, range: range)
    }
    
    /// Download entire file without chunking (for small files or servers without Range support)
    public func downloadFull(
        url: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Data {
        
        try await retryEngine.execute { [self] in
            try await performFullDownload(url: url, onProgress: onProgress)
        } onRetry: { attempt, error, delay in
            print("⚠️ [Full Download] Retry \(attempt) after \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
        }
    }
    
    private func performFullDownload(
        url: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Data {
        let request = URLRequest(url: url)
        let (asyncBytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.httpError(
                statusCode: httpResponse.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        
        let expectedLength = httpResponse.expectedContentLength
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        
        var downloadedBytes: Int64 = 0
        var lastProgressUpdate: Int64 = 0
        let progressInterval: Int64 = 256 * 1024
        
        for try await byte in asyncBytes {
            data.append(byte)
            downloadedBytes += 1
            
            if downloadedBytes - lastProgressUpdate >= progressInterval {
                onProgress?(downloadedBytes, expectedLength > 0 ? expectedLength : downloadedBytes)
                lastProgressUpdate = downloadedBytes
            }
        }
        
        onProgress?(downloadedBytes, downloadedBytes)
        
        return data
    }
    
    /// Invalidate the session
    public func invalidate() {
        session.invalidateAndCancel()
    }
}
