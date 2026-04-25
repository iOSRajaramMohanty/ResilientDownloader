//
//  Version.swift
//  ResilientDownloader
//
//  Package version information
//

import Foundation

/// ResilientDownloader version information
public enum ResilientDownloaderVersion {
    /// Current version string
    public static let version = "1.0.0"
    
    /// Build number
    public static let build = "1"
    
    /// Full version string (e.g., "1.0.0 (1)")
    public static var fullVersion: String {
        "\(version) (\(build))"
    }
    
    /// Release date
    public static let releaseDate = "2026-04-25"
    
    /// Version components
    public static var major: Int { 1 }
    public static var minor: Int { 0 }
    public static var patch: Int { 0 }
}
