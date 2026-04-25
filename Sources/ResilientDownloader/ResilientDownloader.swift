//
//  ResilientDownloader.swift
//  ResilientDownloader
//
//  Main public API for resilient file downloads
//  Supports parallel chunks, resume, retry, and network adaptation
//

import Foundation
import Combine

/// Main entry point for resilient file downloads
/// 
/// Features:
/// - Parallel chunk downloads for faster speeds
/// - Automatic resume after interruption
/// - Exponential backoff retry
/// - Network-adaptive configuration
/// - Progress persistence across app restarts
///
/// Usage:
/// ```swift
/// let task = ResilientDownloader.shared.download(
///     url: modelURL,
///     to: localPath,
///     configuration: .aggressive
/// ) { progress in
///     print("Progress: \(progress.progress * 100)%")
/// }
///
/// // Wait for completion
/// let fileURL = try await task.waitForCompletion()
/// ```
@MainActor
public final class ResilientDownloader: ObservableObject {
    
    /// Shared singleton instance
    public static let shared = ResilientDownloader()
    
    /// Active download tasks
    @Published public private(set) var activeTasks: [String: DownloadTaskHandle] = [:]
    
    /// Current download progress for all tasks
    @Published public private(set) var progressMap: [String: DownloadProgress] = [:]
    
    private let coordinator: DownloadCoordinator
    private let stateStore: DownloadStateStore
    private let fileAssembler: FileAssembler
    private let networkAdapter: NetworkAdapter
    
    private var cancellables = Set<AnyCancellable>()
    
    public init(
        storeDirectory: URL? = nil,
        chunkDirectory: URL? = nil
    ) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("ResilientDownloader", isDirectory: true)
        
        let storeDir = storeDirectory ?? baseDir.appendingPathComponent("States", isDirectory: true)
        let chunkDir = chunkDirectory ?? baseDir.appendingPathComponent("Chunks", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        
        self.stateStore = DownloadStateStore(storeDirectory: storeDir)
        self.fileAssembler = FileAssembler(chunkDirectory: chunkDir)
        self.networkAdapter = NetworkAdapter.shared
        
        self.coordinator = DownloadCoordinator(
            stateStore: stateStore,
            fileAssembler: fileAssembler,
            networkAdapter: networkAdapter
        )
    }
    
    // MARK: - Download
    
    /// Start a new download
    /// - Parameters:
    ///   - url: URL to download from
    ///   - destination: Local file path to save to
    ///   - configuration: Download configuration (optional, uses network-adaptive defaults)
    ///   - progress: Progress callback
    /// - Returns: DownloadTaskHandle to control the download
    public func download(
        url: URL,
        to destination: URL,
        configuration: DownloadConfiguration? = nil,
        progress: @escaping (DownloadProgress) -> Void = { _ in }
    ) -> DownloadTaskHandle {
        
        let taskId = UUID().uuidString
        let handle = DownloadTaskHandle(id: taskId, url: url, destination: destination)
        
        activeTasks[taskId] = handle
        
        let task = Task { [weak self] in
            guard let self = self else { throw DownloadError.cancelled }
            
            return try await self.coordinator.download(
                taskId: taskId,
                url: url,
                destination: destination,
                configuration: configuration
            ) { [weak self] downloadProgress in
                Task { @MainActor in
                    self?.progressMap[taskId] = downloadProgress
                    progress(downloadProgress)
                }
            } onStateChange: { [weak self] status in
                Task { @MainActor in
                    if status == .completed || status == .failed || status == .cancelled {
                        self?.activeTasks.removeValue(forKey: taskId)
                        self?.progressMap.removeValue(forKey: taskId)
                    }
                }
            }
        }
        
        handle.task = task
        
        return handle
    }
    
    /// Start a download with async/await
    public func downloadAsync(
        url: URL,
        to destination: URL,
        configuration: DownloadConfiguration? = nil,
        progress: @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        let handle = download(url: url, to: destination, configuration: configuration, progress: progress)
        return try await handle.waitForCompletion()
    }
    
    // MARK: - Resume
    
    /// Resume a paused or failed download
    public func resume(
        taskId: String,
        progress: @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        
        guard let state = await coordinator.getState(taskId: taskId) else {
            throw DownloadError.invalidResponse
        }
        
        guard state.canResume else {
            throw DownloadError.invalidResponse
        }
        
        let handle = DownloadTaskHandle(id: taskId, url: state.url, destination: state.destination)
        activeTasks[taskId] = handle
        
        let result = try await coordinator.download(
            taskId: taskId,
            url: state.url,
            destination: state.destination,
            configuration: nil
        ) { [weak self] downloadProgress in
            Task { @MainActor in
                self?.progressMap[taskId] = downloadProgress
                progress(downloadProgress)
            }
        } onStateChange: { [weak self] status in
            Task { @MainActor in
                if status == .completed || status == .failed || status == .cancelled {
                    self?.activeTasks.removeValue(forKey: taskId)
                    self?.progressMap.removeValue(forKey: taskId)
                }
            }
        }
        
        return result
    }
    
    /// Get all resumable downloads
    public func getResumableDownloads() async -> [DownloadState] {
        await coordinator.getResumableDownloads()
    }
    
    // MARK: - Control
    
    /// Pause a download
    public func pause(taskId: String) async throws {
        activeTasks[taskId]?.pause()
        try await coordinator.pause(taskId: taskId)
        activeTasks.removeValue(forKey: taskId)
    }
    
    /// Cancel a download
    public func cancel(taskId: String) async {
        activeTasks[taskId]?.cancel()
        await coordinator.cancel(taskId: taskId)
        activeTasks.removeValue(forKey: taskId)
        progressMap.removeValue(forKey: taskId)
    }
    
    /// Cancel all active downloads
    public func cancelAll() async {
        for taskId in activeTasks.keys {
            await cancel(taskId: taskId)
        }
    }
    
    // MARK: - Status
    
    /// Get download state
    public func getState(taskId: String) async -> DownloadState? {
        await coordinator.getState(taskId: taskId)
    }
    
    /// Check if a download is active
    public func isDownloading(taskId: String) -> Bool {
        activeTasks[taskId] != nil
    }
    
    /// Get current progress for a download
    public func progress(for taskId: String) -> DownloadProgress? {
        progressMap[taskId]
    }
    
    // MARK: - Network
    
    /// Current network connection type
    public var connectionType: ConnectionType {
        networkAdapter.connectionType
    }
    
    /// Current estimated network quality
    public var networkQuality: NetworkQuality {
        networkAdapter.estimatedQuality
    }
    
    /// Whether network is connected
    public var isConnected: Bool {
        networkAdapter.isConnected
    }
    
    /// Get optimal configuration for current network
    public func optimalConfiguration() -> DownloadConfiguration {
        networkAdapter.optimalConfiguration()
    }
    
    // MARK: - Cleanup
    
    /// Clean up all temporary files
    public func cleanupTempFiles() async {
        await fileAssembler.cleanupAll()
    }
    
    /// Clear all stored states
    public func clearAllStates() async {
        await stateStore.clearAll()
    }
}

// MARK: - Convenience Extensions

public extension ResilientDownloader {
    
    /// Download multiple files in parallel
    func downloadMultiple(
        urls: [(url: URL, destination: URL)],
        configuration: DownloadConfiguration? = nil,
        progress: @escaping (String, DownloadProgress) -> Void = { _, _ in }
    ) async throws -> [URL] {
        
        try await withThrowingTaskGroup(of: URL.self) { group in
            for (url, destination) in urls {
                group.addTask {
                    try await self.downloadAsync(
                        url: url,
                        to: destination,
                        configuration: configuration
                    ) { downloadProgress in
                        progress(url.lastPathComponent, downloadProgress)
                    }
                }
            }
            
            var results: [URL] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Download with automatic configuration based on network
    func downloadAdaptive(
        url: URL,
        to destination: URL,
        progress: @escaping (DownloadProgress) -> Void = { _ in }
    ) -> DownloadTaskHandle {
        download(
            url: url,
            to: destination,
            configuration: optimalConfiguration(),
            progress: progress
        )
    }
}
