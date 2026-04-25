//
//  NetworkAdapter.swift
//  ResilientDownloader
//
//  Monitors network conditions and adapts download strategy
//

import Foundation
import Network

/// Network connection type
public enum ConnectionType: String, Sendable {
    case wifi
    case cellular
    case ethernet
    case unknown
    case none
}

/// Network quality estimation
public enum NetworkQuality: String, Sendable {
    case excellent
    case good
    case moderate
    case poor
    case none
}

/// Adapts download strategy based on network conditions
public final class NetworkAdapter: @unchecked Sendable {
    
    public static let shared = NetworkAdapter()
    
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.resilientdownloader.network")
    
    private var _isConnected: Bool = true
    private var _connectionType: ConnectionType = .unknown
    private var _isExpensive: Bool = false
    private var _isConstrained: Bool = false
    
    private let lock = NSLock()
    
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }
    
    public var connectionType: ConnectionType {
        lock.lock()
        defer { lock.unlock() }
        return _connectionType
    }
    
    public var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpensive
    }
    
    public var isConstrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConstrained
    }
    
    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateNetworkStatus(path)
        }
        monitor.start(queue: queue)
    }
    
    private func updateNetworkStatus(_ path: NWPath) {
        lock.lock()
        defer { lock.unlock() }
        
        _isConnected = path.status == .satisfied
        _isExpensive = path.isExpensive
        _isConstrained = path.isConstrained
        
        if path.usesInterfaceType(.wifi) {
            _connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            _connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            _connectionType = .ethernet
        } else if path.status == .satisfied {
            _connectionType = .unknown
        } else {
            _connectionType = .none
        }
    }
    
    /// Estimate network quality based on connection type and constraints
    public var estimatedQuality: NetworkQuality {
        guard isConnected else { return .none }
        
        if isConstrained {
            return .poor
        }
        
        switch connectionType {
        case .wifi, .ethernet:
            return isExpensive ? .moderate : .excellent
        case .cellular:
            return isExpensive ? .moderate : .good
        case .unknown:
            return .moderate
        case .none:
            return .none
        }
    }
    
    /// Get optimal configuration for current network conditions
    public func optimalConfiguration(base: DownloadConfiguration = .default) -> DownloadConfiguration {
        var config = base
        
        switch estimatedQuality {
        case .excellent:
            config.chunkSize = 4 * 1024 * 1024      // 4 MB
            config.maxConcurrentChunks = 6
            config.initialRetryDelay = 1.0
        case .good:
            config.chunkSize = 2 * 1024 * 1024      // 2 MB
            config.maxConcurrentChunks = 4
            config.initialRetryDelay = 1.0
        case .moderate:
            config.chunkSize = 512 * 1024           // 512 KB
            config.maxConcurrentChunks = 2
            config.initialRetryDelay = 2.0
        case .poor:
            config.chunkSize = 128 * 1024           // 128 KB
            config.maxConcurrentChunks = 1
            config.initialRetryDelay = 3.0
            config.maxRetries = 20
        case .none:
            config.maxConcurrentChunks = 0
        }
        
        return config
    }
    
    /// Optimal chunk size for current network
    public var optimalChunkSize: Int {
        switch estimatedQuality {
        case .excellent:
            return 4 * 1024 * 1024
        case .good:
            return 2 * 1024 * 1024
        case .moderate:
            return 512 * 1024
        case .poor:
            return 128 * 1024
        case .none:
            return 256 * 1024
        }
    }
    
    /// Optimal concurrent downloads for current network
    public var optimalConcurrency: Int {
        switch estimatedQuality {
        case .excellent:
            return 6
        case .good:
            return 4
        case .moderate:
            return 2
        case .poor, .none:
            return 1
        }
    }
    
    /// Wait for network to become available
    public func waitForConnection(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if isConnected {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        return isConnected
    }
}
