//
//  DownloadCoordinator.swift
//  ResilientDownloader
//
//  Orchestrates parallel chunk downloads
//

import Foundation

/// Coordinates parallel chunk downloads for a file
public actor DownloadCoordinator {
    
    private let stateStore: DownloadStateStore
    private let fileAssembler: FileAssembler
    private let networkAdapter: NetworkAdapter
    private var configuration: DownloadConfiguration
    
    private var activeDownloaders: [String: ChunkDownloader] = [:]
    private var downloadStartTimes: [String: Date] = [:]
    private var bytesAtLastSpeedCheck: [String: Int64] = [:]
    private var currentSpeeds: [String: Double] = [:]
    
    public init(
        stateStore: DownloadStateStore,
        fileAssembler: FileAssembler,
        networkAdapter: NetworkAdapter = .shared,
        configuration: DownloadConfiguration = .default
    ) {
        self.stateStore = stateStore
        self.fileAssembler = fileAssembler
        self.networkAdapter = networkAdapter
        self.configuration = configuration
    }
    
    /// Create chunk ranges for a file
    private func createChunks(totalBytes: Int64, chunkSize: Int) -> [ChunkRange] {
        var chunks: [ChunkRange] = []
        var start: Int64 = 0
        
        while start < totalBytes {
            let end = min(start + Int64(chunkSize) - 1, totalBytes - 1)
            chunks.append(ChunkRange(start: start, end: end))
            start = end + 1
        }
        
        return chunks
    }
    
    /// Start or resume a download
    public func download(
        taskId: String,
        url: URL,
        destination: URL,
        configuration: DownloadConfiguration? = nil,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onStateChange: @escaping @Sendable (DownloadStatus) -> Void
    ) async throws -> URL {
        
        let config = configuration ?? networkAdapter.optimalConfiguration(base: self.configuration)
        
        let downloader = ChunkDownloader(configuration: config)
        activeDownloaders[taskId] = downloader
        downloadStartTimes[taskId] = Date()
        bytesAtLastSpeedCheck[taskId] = 0
        
        defer {
            activeDownloaders.removeValue(forKey: taskId)
            downloadStartTimes.removeValue(forKey: taskId)
            bytesAtLastSpeedCheck.removeValue(forKey: taskId)
            currentSpeeds.removeValue(forKey: taskId)
        }
        
        var state = try await stateStore.load(taskId: taskId)
        
        if state == nil || state?.status == .completed {
            let fileInfo = try await downloader.getFileInfo(url: url)
            
            guard fileInfo.contentLength > 0 else {
                throw DownloadError.unableToGetFileSize
            }
            
            let chunks: [ChunkRange]
            let chunkStates: [ChunkState]
            
            if fileInfo.acceptsRanges {
                chunks = createChunks(totalBytes: fileInfo.contentLength, chunkSize: config.chunkSize)
                chunkStates = chunks.enumerated().map { index, range in
                    ChunkState(index: index, range: range)
                }
            } else {
                chunks = [ChunkRange(start: 0, end: fileInfo.contentLength - 1)]
                chunkStates = [ChunkState(index: 0, range: chunks[0])]
            }
            
            state = DownloadState(
                id: taskId,
                url: url,
                destination: destination,
                totalBytes: fileInfo.contentLength,
                chunks: chunkStates,
                status: .downloading,
                expectedChecksum: config.expectedChecksum
            )
            
            try await stateStore.save(state!)
            onStateChange(.downloading)
        } else {
            state!.status = .downloading
            try await stateStore.save(state!)
            onStateChange(.downloading)
        }
        
        guard var downloadState = state else {
            throw DownloadError.invalidResponse
        }
        
        print("📦 [Download] Starting \(downloadState.chunks.count) chunks for \(url.lastPathComponent)")
        print("📊 [Config] Chunk size: \(ByteCountFormatter.string(fromByteCount: Int64(config.chunkSize), countStyle: .file)), Concurrency: \(config.maxConcurrentChunks)")
        
        let acceptsRanges = downloadState.chunks.count > 1 || downloadState.chunks.first?.range.start != 0
        
        do {
            if acceptsRanges {
                try await downloadWithChunks(
                    taskId: taskId,
                    state: &downloadState,
                    downloader: downloader,
                    config: config,
                    onProgress: onProgress
                )
            } else {
                try await downloadWithoutChunks(
                    taskId: taskId,
                    state: &downloadState,
                    downloader: downloader,
                    onProgress: onProgress
                )
            }
            
            try await fileAssembler.assembleChunks(
                taskId: taskId,
                chunkCount: downloadState.chunks.count,
                destination: downloadState.destination,
                expectedChecksum: downloadState.expectedChecksum
            )
            
            await fileAssembler.cleanupChunks(taskId: taskId, chunkCount: downloadState.chunks.count)
            
            downloadState.status = .completed
            downloadState.downloadedBytes = downloadState.totalBytes
            try await stateStore.save(downloadState)
            onStateChange(.completed)
            
            print("✅ [Download] Completed: \(destination.lastPathComponent)")
            
            return destination
            
        } catch {
            if error is CancellationError {
                downloadState.status = .cancelled
                try? await stateStore.save(downloadState)
                onStateChange(.cancelled)
                throw DownloadError.cancelled
            }
            
            downloadState.status = .failed
            downloadState.lastError = error.localizedDescription
            try? await stateStore.save(downloadState)
            onStateChange(.failed)
            
            throw error
        }
    }
    
    /// Download using parallel chunks
    private func downloadWithChunks(
        taskId: String,
        state: inout DownloadState,
        downloader: ChunkDownloader,
        config: DownloadConfiguration,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        
        let pendingIndices = state.chunks.enumerated()
            .filter { $0.element.status != .completed }
            .map { $0.offset }
        
        guard !pendingIndices.isEmpty else { return }
        
        let totalBytes = state.totalBytes
        let url = state.url
        var completedBytes: Int64 = state.chunks
            .filter { $0.status == .completed }
            .reduce(0) { $0 + $1.range.length }
        
        try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            var pendingQueue = pendingIndices
            var activeCount = 0
            let maxConcurrent = config.maxConcurrentChunks
            
            while !pendingQueue.isEmpty || activeCount > 0 {
                try Task.checkCancellation()
                
                while activeCount < maxConcurrent && !pendingQueue.isEmpty {
                    let chunkIndex = pendingQueue.removeFirst()
                    let chunk = state.chunks[chunkIndex]
                    
                    activeCount += 1
                    
                    let currentCompletedBytes = completedBytes
                    
                    group.addTask { [self] in
                        try await downloader.downloadChunk(
                            url: url,
                            range: chunk.range,
                            chunkIndex: chunkIndex
                        ) { bytesDownloaded in
                            Task { @MainActor in
                                let progress = Double(currentCompletedBytes + bytesDownloaded) / Double(totalBytes)
                                let speed = await self.calculateSpeed(
                                    taskId: taskId,
                                    currentBytes: currentCompletedBytes + bytesDownloaded
                                )
                                
                                let eta: TimeInterval?
                                if speed > 0 {
                                    let remaining = totalBytes - currentCompletedBytes - bytesDownloaded
                                    eta = Double(remaining) / speed
                                } else {
                                    eta = nil
                                }
                                
                                onProgress(DownloadProgress(
                                    taskId: taskId,
                                    progress: progress,
                                    downloadedBytes: currentCompletedBytes + bytesDownloaded,
                                    totalBytes: totalBytes,
                                    bytesPerSecond: speed,
                                    estimatedTimeRemaining: eta
                                ))
                            }
                        }
                    }
                }
                
                if let result = try await group.next() {
                    activeCount -= 1
                    
                    try await fileAssembler.saveChunk(
                        result.data,
                        taskId: taskId,
                        chunkIndex: result.chunkIndex
                    )
                    
                    state.chunks[result.chunkIndex].status = .completed
                    state.chunks[result.chunkIndex].downloadedBytes = result.range.length
                    completedBytes += result.range.length
                    
                    state.downloadedBytes = completedBytes
                    try await stateStore.save(state)
                    
                    print("✓ Chunk \(result.chunkIndex + 1)/\(state.chunks.count) complete")
                }
            }
        }
    }
    
    /// Download without chunking (single connection)
    private func downloadWithoutChunks(
        taskId: String,
        state: inout DownloadState,
        downloader: ChunkDownloader,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        
        let data = try await downloader.downloadFull(url: state.url) { [self] downloaded, total in
            Task { @MainActor in
                let progress = Double(downloaded) / Double(total)
                let speed = await self.calculateSpeed(taskId: taskId, currentBytes: downloaded)
                
                let eta: TimeInterval?
                if speed > 0 {
                    eta = Double(total - downloaded) / speed
                } else {
                    eta = nil
                }
                
                onProgress(DownloadProgress(
                    taskId: taskId,
                    progress: progress,
                    downloadedBytes: downloaded,
                    totalBytes: total,
                    bytesPerSecond: speed,
                    estimatedTimeRemaining: eta
                ))
            }
        }
        
        try await fileAssembler.saveChunk(data, taskId: taskId, chunkIndex: 0)
        
        state.chunks[0].status = .completed
        state.chunks[0].downloadedBytes = Int64(data.count)
        state.downloadedBytes = Int64(data.count)
        try await stateStore.save(state)
    }
    
    /// Calculate download speed
    private func calculateSpeed(taskId: String, currentBytes: Int64) -> Double {
        guard let startTime = downloadStartTimes[taskId] else { return 0 }
        
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0.5 else { return 0 }
        
        let lastBytes = bytesAtLastSpeedCheck[taskId] ?? 0
        let bytesDiff = currentBytes - lastBytes
        
        bytesAtLastSpeedCheck[taskId] = currentBytes
        
        let newSpeed = Double(bytesDiff) / elapsed
        let oldSpeed = currentSpeeds[taskId] ?? newSpeed
        
        let smoothedSpeed = (oldSpeed * 0.7) + (newSpeed * 0.3)
        currentSpeeds[taskId] = smoothedSpeed
        downloadStartTimes[taskId] = Date()
        
        return smoothedSpeed
    }
    
    /// Pause a download
    public func pause(taskId: String) async throws {
        try await stateStore.updateStatus(taskId: taskId, status: .paused)
        if let downloader = activeDownloaders[taskId] {
            await downloader.invalidate()
        }
        activeDownloaders.removeValue(forKey: taskId)
    }
    
    /// Cancel a download
    public func cancel(taskId: String) async {
        if let downloader = activeDownloaders[taskId] {
            await downloader.invalidate()
        }
        activeDownloaders.removeValue(forKey: taskId)
        
        if let state = try? await stateStore.load(taskId: taskId) {
            await fileAssembler.cleanupChunks(taskId: taskId, chunkCount: state.chunks.count)
        }
        
        await stateStore.delete(taskId: taskId)
    }
    
    /// Get current state for a download
    public func getState(taskId: String) async -> DownloadState? {
        try? await stateStore.load(taskId: taskId)
    }
    
    /// Get all resumable downloads
    public func getResumableDownloads() async -> [DownloadState] {
        await stateStore.resumableStates()
    }
}
