//
//  Checksum.swift
//  ResilientDownloader
//
//  SHA256 checksum calculation and verification
//

import Foundation
import CryptoKit

/// Utility for calculating and verifying file checksums
public struct Checksum {
    
    /// Calculate SHA256 hash of data
    public static func sha256(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Calculate SHA256 hash of a file
    public static func sha256(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB buffer
        
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty {
                return false
            }
            hasher.update(data: data)
            return true
        }) {}
        
        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify a file's checksum matches expected value
    public static func verify(fileURL: URL, expectedChecksum: String) throws -> Bool {
        let actualChecksum = try sha256(fileURL: fileURL)
        return actualChecksum.lowercased() == expectedChecksum.lowercased()
    }
    
    /// Calculate MD5 hash of data (for compatibility with some servers)
    public static func md5(data: Data) -> String {
        let hash = Insecure.MD5.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
