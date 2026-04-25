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
    
    /// Track individual chunk progress for visual display
    private var chunkProgress: [String: [Int: Double]] = [:]  // taskId -> [chunkIndex: progress]
    private var chunkRanges: [String: [ChunkRange]] = [:]
    private var lastVisualUpdate: [String: Date] = [:]
    
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
    /// Uses smart chunk sizing based on file size to avoid too many chunks
    private func createChunks(totalBytes: Int64, chunkSize: Int) -> [ChunkRange] {
        // Calculate optimal chunk size based on file size
        // Goal: 4-20 chunks for most files
        let optimalChunkSize: Int64
        let maxChunks = 20
        
        if totalBytes < 10 * 1024 * 1024 {
            // < 10MB: use config chunk size (small files benefit from small chunks)
            optimalChunkSize = Int64(chunkSize)
        } else if totalBytes < 100 * 1024 * 1024 {
            // 10-100MB: 2-5MB chunks
            optimalChunkSize = max(Int64(chunkSize), 2 * 1024 * 1024)
        } else if totalBytes < 500 * 1024 * 1024 {
            // 100-500MB: aim for ~10 chunks
            optimalChunkSize = max(totalBytes / 10, 10 * 1024 * 1024)
        } else {
            // > 500MB: aim for ~maxChunks chunks (20)
            optimalChunkSize = max(totalBytes / Int64(maxChunks), 20 * 1024 * 1024)
        }
        
        var chunks: [ChunkRange] = []
        var start: Int64 = 0
        
        while start < totalBytes {
            let end = min(start + optimalChunkSize - 1, totalBytes - 1)
            chunks.append(ChunkRange(start: start, end: end))
            start = end + 1
        }
        
        // Log the chunk strategy
        let chunkSizeMB = Double(optimalChunkSize) / 1_000_000
        print("📊 [Chunks] \(chunks.count) chunks of ~\(String(format: "%.1f", chunkSizeMB))MB for \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) file")
        
        return chunks
    }
    
    // MARK: - Visual Progress Display
    
    /// Render a progress bar string
    private func renderProgressBar(progress: Double, width: Int = 30) -> String {
        let filled = Int(progress * Double(width))
        let empty = width - filled
        let filledBar = String(repeating: "█", count: max(0, min(filled, width)))
        let emptyBar = String(repeating: "░", count: max(0, min(empty, width)))
        return "[\(filledBar)\(emptyBar)]"
    }
    
    /// Format byte range for display
    private func formatRange(_ range: ChunkRange) -> String {
        let startMB = Double(range.start) / 1_000_000
        let endMB = Double(range.end + 1) / 1_000_000
        
        if endMB < 1 {
            return "\(Int(startMB * 1000))-\(Int(endMB * 1000))KB"
        } else if endMB < 1000 {
            return "\(String(format: "%.0f", startMB))-\(String(format: "%.0f", endMB))MB"
        } else {
            return "\(String(format: "%.1f", startMB/1000))-\(String(format: "%.1f", endMB/1000))GB"
        }
    }
    
    /// Display visual progress for all active chunks
    private func displayChunkProgress(taskId: String, totalChunks: Int) {
        guard let progress = chunkProgress[taskId],
              let ranges = chunkRanges[taskId] else { return }
        
        // Only update every 500ms to avoid console spam
        let now = Date()
        if let lastUpdate = lastVisualUpdate[taskId],
           now.timeIntervalSince(lastUpdate) < 0.5 {
            return
        }
        lastVisualUpdate[taskId] = now
        
        // Calculate stats
        let completedChunks = progress.values.filter { $0 >= 1.0 }.count
        let overallProgress = progress.values.reduce(0.0, +) / Double(max(1, totalChunks))
        
        // Only show chunks that have started (progress > 0)
        let activeChunks = progress.filter { $0.value > 0 && $0.value < 1.0 }
            .sorted { $0.key < $1.key }
        
        // Skip display if nothing active
        if activeChunks.isEmpty && completedChunks == 0 {
            return
        }
        
        print("\n📊 Progress: \(completedChunks)/\(totalChunks) chunks complete")
        print("─────────────────────────────────────────────────────────")
        
        // Show only active (in-progress) chunks
        for (index, prog) in activeChunks {
            let range = ranges[index]
            let rangeStr = formatRange(range).padding(toLength: 14, withPad: " ", startingAt: 0)
            let bar = renderProgressBar(progress: prog)
            let percent = Int(prog * 100)
            print("  Chunk \(index + 1) [\(rangeStr)]: \(bar) \(String(format: "%3d", percent))%")
        }
        
        let overallBar = renderProgressBar(progress: overallProgress, width: 40)
        print("─────────────────────────────────────────────────────────")
        print("  Overall: \(overallBar) \(Int(overallProgress * 100))%")
        print("")
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
        
        // Initialize chunk progress tracking
        let totalChunks = state.chunks.count
        chunkProgress[taskId] = [:]
        chunkRanges[taskId] = state.chunks.map { $0.range }
        
        // Mark already completed chunks
        for (index, chunk) in state.chunks.enumerated() {
            if chunk.status == .completed {
                chunkProgress[taskId]?[index] = 1.0
            } else {
                chunkProgress[taskId]?[index] = 0.0
            }
        }
        
        defer {
            // Cleanup tracking
            chunkProgress.removeValue(forKey: taskId)
            chunkRanges.removeValue(forKey: taskId)
            lastVisualUpdate.removeValue(forKey: taskId)
        }
        
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
                    let chunkLength = chunk.range.length
                    
                    group.addTask { [self] in
                        try await downloader.downloadChunk(
                            url: url,
                            range: chunk.range,
                            chunkIndex: chunkIndex
                        ) { bytesDownloaded in
                            Task { @MainActor in
                                // Update individual chunk progress
                                let chunkProg = Double(bytesDownloaded) / Double(chunkLength)
                                await self.updateChunkProgress(taskId: taskId, chunkIndex: chunkIndex, progress: chunkProg)
                                
                                // Display visual progress (throttled internally)
                                await self.displayChunkProgress(taskId: taskId, totalChunks: totalChunks)
                                
                                // Calculate overall progress
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
                    
                    // Mark chunk as 100% complete
                    chunkProgress[taskId]?[result.chunkIndex] = 1.0
                    
                    state.downloadedBytes = completedBytes
                    try await stateStore.save(state)
                    
                    print("✓ Chunk \(result.chunkIndex + 1)/\(state.chunks.count) complete")
                }
            }
        }
    }
    
    /// Update progress for a specific chunk
    private func updateChunkProgress(taskId: String, chunkIndex: Int, progress: Double) {
        chunkProgress[taskId]?[chunkIndex] = min(1.0, progress)
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
