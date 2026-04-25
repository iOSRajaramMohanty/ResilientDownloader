//
//  FileAssembler.swift
//  ResilientDownloader
//
//  Assembles downloaded chunks into final file
//

import Foundation

/// Assembles downloaded chunks into the final file
public actor FileAssembler {
    
    private let fileManager = FileManager.default
    private let chunkDirectory: URL
    
    public init(chunkDirectory: URL) {
        self.chunkDirectory = chunkDirectory
    }
    
    /// Get the path for a chunk file
    public func chunkPath(for taskId: String, chunkIndex: Int) -> URL {
        chunkDirectory.appendingPathComponent("\(taskId)_chunk_\(chunkIndex).tmp")
    }
    
    /// Save a chunk to disk
    public func saveChunk(_ data: Data, taskId: String, chunkIndex: Int) throws {
        let path = chunkPath(for: taskId, chunkIndex: chunkIndex)
        try data.write(to: path, options: .atomic)
    }
    
    /// Load a chunk from disk
    public func loadChunk(taskId: String, chunkIndex: Int) throws -> Data {
        let path = chunkPath(for: taskId, chunkIndex: chunkIndex)
        return try Data(contentsOf: path)
    }
    
    /// Check if a chunk exists
    public func chunkExists(taskId: String, chunkIndex: Int) -> Bool {
        let path = chunkPath(for: taskId, chunkIndex: chunkIndex)
        return fileManager.fileExists(atPath: path.path)
    }
    
    /// Get size of a chunk
    public func chunkSize(taskId: String, chunkIndex: Int) -> Int64 {
        let path = chunkPath(for: taskId, chunkIndex: chunkIndex)
        guard let attrs = try? fileManager.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }
    
    /// Assemble all chunks into the final file
    public func assembleChunks(
        taskId: String,
        chunkCount: Int,
        destination: URL,
        expectedChecksum: String? = nil
    ) throws {
        let destinationDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDir.path) {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }
        
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        
        fileManager.createFile(atPath: destination.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destination)
        defer { try? fileHandle.close() }
        
        for index in 0..<chunkCount {
            let chunkPath = self.chunkPath(for: taskId, chunkIndex: index)
            guard fileManager.fileExists(atPath: chunkPath.path) else {
                throw DownloadError.fileSystemError(underlying: "Missing chunk \(index)")
            }
            
            let chunkData = try Data(contentsOf: chunkPath)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: chunkData)
        }
        
        try fileHandle.synchronize()
        
        if let expectedChecksum = expectedChecksum {
            let actualChecksum = try Checksum.sha256(fileURL: destination)
            if actualChecksum.lowercased() != expectedChecksum.lowercased() {
                try? fileManager.removeItem(at: destination)
                throw DownloadError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
            }
        }
    }
    
    /// Clean up chunk files for a task
    public func cleanupChunks(taskId: String, chunkCount: Int) {
        for index in 0..<chunkCount {
            let path = chunkPath(for: taskId, chunkIndex: index)
            try? fileManager.removeItem(at: path)
        }
    }
    
    /// Clean up all temporary files
    public func cleanupAll() {
        guard let contents = try? fileManager.contentsOfDirectory(at: chunkDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        for file in contents where file.pathExtension == "tmp" {
            try? fileManager.removeItem(at: file)
        }
    }
    
    /// Get total size of chunks for a task
    public func totalChunkSize(taskId: String, chunkCount: Int) -> Int64 {
        var total: Int64 = 0
        for index in 0..<chunkCount {
            total += chunkSize(taskId: taskId, chunkIndex: index)
        }
        return total
    }
}
