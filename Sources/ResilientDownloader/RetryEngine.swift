//
//  RetryEngine.swift
//  ResilientDownloader
//
//  Exponential backoff retry logic with jitter
//

import Foundation

/// Handles retry logic with exponential backoff and jitter
public actor RetryEngine {
    
    private let initialDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let maxRetries: Int
    private let jitterFactor: Double
    
    public init(
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        maxRetries: Int = 10,
        jitterFactor: Double = 0.3
    ) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
        self.jitterFactor = jitterFactor
    }
    
    /// Calculate delay for a given retry attempt
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        
        let exponentialDelay = initialDelay * pow(2.0, Double(attempt - 1))
        let cappedDelay = min(exponentialDelay, maxDelay)
        
        let jitter = cappedDelay * jitterFactor * Double.random(in: -1...1)
        let finalDelay = max(0, cappedDelay + jitter)
        
        return finalDelay
    }
    
    /// Check if retry should be attempted
    public func shouldRetry(attempt: Int) -> Bool {
        attempt < maxRetries
    }
    
    /// Execute an operation with retries
    public func execute<T: Sendable>(
        operation: @Sendable () async throws -> T,
        onRetry: (@Sendable (Int, Error, TimeInterval) async -> Void)? = nil
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                
                if !shouldRetry(attempt: attempt + 1) {
                    break
                }
                
                if error is CancellationError {
                    throw error
                }
                
                if let downloadError = error as? DownloadError {
                    switch downloadError {
                    case .cancelled, .checksumMismatch, .noSpaceOnDisk:
                        throw error
                    default:
                        break
                    }
                }
                
                let retryDelay = delay(forAttempt: attempt + 1)
                await onRetry?(attempt + 1, error, retryDelay)
                
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        
        throw lastError ?? DownloadError.maxRetriesExceeded(chunk: -1, lastError: nil)
    }
    
    /// Execute with custom retry decision
    public func executeWithDecision<T: Sendable>(
        operation: @Sendable () async throws -> T,
        shouldRetryError: @Sendable (Error) -> Bool,
        onRetry: (@Sendable (Int, Error, TimeInterval) async -> Void)? = nil
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                
                if !shouldRetry(attempt: attempt + 1) || !shouldRetryError(error) {
                    throw error
                }
                
                let retryDelay = delay(forAttempt: attempt + 1)
                await onRetry?(attempt + 1, error, retryDelay)
                
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        
        throw lastError ?? DownloadError.maxRetriesExceeded(chunk: -1, lastError: nil)
    }
}

/// Determines if an HTTP status code is retryable
public func isRetryableStatusCode(_ statusCode: Int) -> Bool {
    switch statusCode {
    case 408, 425, 429, 500, 502, 503, 504:
        return true
    default:
        return false
    }
}

/// Determines if a URL error is retryable
public func isRetryableURLError(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut,
         .cannotFindHost,
         .cannotConnectToHost,
         .networkConnectionLost,
         .dnsLookupFailed,
         .notConnectedToInternet,
         .internationalRoamingOff,
         .callIsActive,
         .dataNotAllowed,
         .secureConnectionFailed:
        return true
    default:
        return false
    }
}
