//
//  DownloadConfiguration.swift
//  ResilientDownloader
//
//  Configuration options for resilient downloads
//

import Foundation

/// Configuration for download behavior
public struct DownloadConfiguration: Sendable {
    
    /// Size of each download chunk in bytes
    public var chunkSize: Int
    
    /// Maximum number of concurrent chunk downloads
    public var maxConcurrentChunks: Int
    
    /// Maximum retry attempts per chunk
    public var maxRetries: Int
    
    /// Initial delay before first retry (in seconds)
    public var initialRetryDelay: TimeInterval
    
    /// Maximum delay between retries (in seconds)
    public var maxRetryDelay: TimeInterval
    
    /// Whether to use iOS background URLSession
    public var useBackgroundSession: Bool
    
    /// Whether to verify file checksum after download
    public var verifyChecksum: Bool
    
    /// Expected SHA256 checksum (optional)
    public var expectedChecksum: String?
    
    /// Timeout for individual chunk requests (in seconds)
    public var chunkTimeout: TimeInterval
    
    /// Whether to allow cellular network downloads
    public var allowsCellularAccess: Bool
    
    /// Whether to allow downloads on constrained networks (Low Data Mode)
    public var allowsConstrainedNetworkAccess: Bool
    
    /// Whether to allow downloads on expensive networks
    public var allowsExpensiveNetworkAccess: Bool
    
    public init(
        chunkSize: Int = 2 * 1024 * 1024,  // 2 MB default
        maxConcurrentChunks: Int = 4,
        maxRetries: Int = 10,
        initialRetryDelay: TimeInterval = 1.0,
        maxRetryDelay: TimeInterval = 60.0,
        useBackgroundSession: Bool = true,
        verifyChecksum: Bool = true,
        expectedChecksum: String? = nil,
        chunkTimeout: TimeInterval = 120.0,
        allowsCellularAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true
    ) {
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.maxRetries = maxRetries
        self.initialRetryDelay = initialRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.useBackgroundSession = useBackgroundSession
        self.verifyChecksum = verifyChecksum
        self.expectedChecksum = expectedChecksum
        self.chunkTimeout = chunkTimeout
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
    }
    
    /// Default configuration - balanced for typical use
    public static let `default` = DownloadConfiguration()
    
    /// Aggressive configuration - optimized for poor/unstable networks
    public static let aggressive = DownloadConfiguration(
        chunkSize: 256 * 1024,           // 256 KB chunks
        maxConcurrentChunks: 2,          // Fewer concurrent
        maxRetries: 20,                  // More retries
        initialRetryDelay: 0.5,          // Faster initial retry
        maxRetryDelay: 120.0,            // Longer max delay
        chunkTimeout: 300.0              // Longer timeout
    )
    
    /// Conservative configuration - battery and data saving
    public static let conservative = DownloadConfiguration(
        chunkSize: 4 * 1024 * 1024,      // 4 MB chunks
        maxConcurrentChunks: 2,          // Fewer connections
        maxRetries: 5,                   // Fewer retries
        initialRetryDelay: 2.0,          // Slower retry
        maxRetryDelay: 30.0,
        chunkTimeout: 60.0
    )
    
    /// WiFi-optimized configuration - maximum speed on good connections
    public static let wifiOptimized = DownloadConfiguration(
        chunkSize: 4 * 1024 * 1024,      // 4 MB chunks
        maxConcurrentChunks: 6,          // More parallel downloads
        maxRetries: 5,
        initialRetryDelay: 1.0,
        maxRetryDelay: 30.0,
        chunkTimeout: 60.0
    )
    
    /// Cellular-optimized configuration - balanced for mobile networks
    public static let cellularOptimized = DownloadConfiguration(
        chunkSize: 512 * 1024,           // 512 KB chunks
        maxConcurrentChunks: 2,          // Limited concurrent
        maxRetries: 15,
        initialRetryDelay: 1.0,
        maxRetryDelay: 60.0,
        chunkTimeout: 180.0
    )
}
