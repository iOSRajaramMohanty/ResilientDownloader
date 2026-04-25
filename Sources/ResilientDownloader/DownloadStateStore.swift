//
//  DownloadStateStore.swift
//  ResilientDownloader
//
//  Persists download state to disk for resume capability
//

import Foundation

/// Persists download states to disk for resume capability
public actor DownloadStateStore {
    
    private let storeDirectory: URL
    private let fileManager = FileManager.default
    private var cachedStates: [String: DownloadState] = [:]
    
    public init(storeDirectory: URL? = nil) {
        if let dir = storeDirectory {
            self.storeDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storeDirectory = appSupport.appendingPathComponent("ResilientDownloader/States", isDirectory: true)
        }
        
        try? fileManager.createDirectory(at: self.storeDirectory, withIntermediateDirectories: true)
    }
    
    private func statePath(for taskId: String) -> URL {
        storeDirectory.appendingPathComponent("\(taskId).json")
    }
    
    /// Save download state
    public func save(_ state: DownloadState) throws {
        cachedStates[state.id] = state
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        let data = try encoder.encode(state)
        let path = statePath(for: state.id)
        try data.write(to: path, options: .atomic)
    }
    
    /// Load download state
    public func load(taskId: String) throws -> DownloadState? {
        if let cached = cachedStates[taskId] {
            return cached
        }
        
        let path = statePath(for: taskId)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let state = try decoder.decode(DownloadState.self, from: data)
        cachedStates[taskId] = state
        return state
    }
    
    /// Delete download state
    public func delete(taskId: String) {
        cachedStates.removeValue(forKey: taskId)
        let path = statePath(for: taskId)
        try? fileManager.removeItem(at: path)
    }
    
    /// Get all stored states
    public func allStates() -> [DownloadState] {
        guard let contents = try? fileManager.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return Array(cachedStates.values)
        }
        
        var states: [DownloadState] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        for file in contents where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let state = try? decoder.decode(DownloadState.self, from: data) {
                states.append(state)
                cachedStates[state.id] = state
            }
        }
        
        return states
    }
    
    /// Get states that can be resumed
    public func resumableStates() -> [DownloadState] {
        allStates().filter { $0.canResume }
    }
    
    /// Update chunk state
    public func updateChunk(taskId: String, chunkIndex: Int, update: (inout ChunkState) -> Void) throws {
        guard var state = try load(taskId: taskId) else { return }
        guard chunkIndex < state.chunks.count else { return }
        
        update(&state.chunks[chunkIndex])
        state.recalculateProgress()
        try save(state)
    }
    
    /// Update download status
    public func updateStatus(taskId: String, status: DownloadStatus, error: String? = nil) throws {
        guard var state = try load(taskId: taskId) else { return }
        state.status = status
        state.lastError = error
        state.updatedAt = Date()
        try save(state)
    }
    
    /// Clear all states
    public func clearAll() {
        cachedStates.removeAll()
        guard let contents = try? fileManager.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in contents {
            try? fileManager.removeItem(at: file)
        }
    }
    
    /// Get storage size used by states
    public func storageUsed() -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        var total: Int64 = 0
        for file in contents {
            if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
