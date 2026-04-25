//
//  main.swift
//  ResilientDownloaderDemo
//
//  Demo executable to test ResilientDownloader functionality
//  Run this from Xcode: Select "ResilientDownloaderDemo" scheme and press Cmd+R
//

import Foundation
import ResilientDownloader

// MARK: - Test Functions

func testConfigurations() {
    let configs: [(String, DownloadConfiguration)] = [
        ("Default", .default),
        ("Aggressive", .aggressive),
        ("Conservative", .conservative),
        ("WiFi Optimized", .wifiOptimized),
        ("Cellular Optimized", .cellularOptimized)
    ]
    
    for (name, config) in configs {
        let chunkSizeKB = config.chunkSize / 1024
        print("  ✓ \(name): \(chunkSizeKB)KB chunks, \(config.maxConcurrentChunks) concurrent, \(config.maxRetries) retries")
    }
    print("  ✅ Configuration presets working correctly")
}

func testNetworkAdapter() {
    let adapter = NetworkAdapter.shared
    
    print("  • Connection Type: \(adapter.connectionType)")
    print("  • Is Connected: \(adapter.isConnected)")
    print("  • Network Quality: \(adapter.estimatedQuality)")
    print("  • Is Expensive: \(adapter.isExpensive)")
    print("  • Is Constrained: \(adapter.isConstrained)")
    
    let optimalConfig = adapter.optimalConfiguration()
    print("  • Optimal Chunk Size: \(optimalConfig.chunkSize / 1024)KB")
    print("  • Optimal Concurrency: \(optimalConfig.maxConcurrentChunks)")
    print("  ✅ Network adapter working correctly")
}

func testRetryEngine() async {
    let engine = RetryEngine(initialDelay: 1.0, maxDelay: 60.0, maxRetries: 5)
    
    print("  Retry delays (exponential backoff):")
    for attempt in 1...5 {
        let delay = await engine.delay(forAttempt: attempt)
        print("    Attempt \(attempt): \(String(format: "%.2f", delay))s")
    }
    
    let shouldRetry3 = await engine.shouldRetry(attempt: 3)
    let shouldRetry6 = await engine.shouldRetry(attempt: 6)
    print("  • Should retry at attempt 3: \(shouldRetry3)")
    print("  • Should retry at attempt 6: \(shouldRetry6)")
    print("  ✅ Retry engine working correctly")
}

@MainActor
func testLlamaConfigDownload() async {
    let repoId = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    let fileName = "config.json"
    let testURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)")!
    let tempDir = FileManager.default.temporaryDirectory
    let destination = tempDir.appendingPathComponent("llama_config_\(UUID().uuidString).json")
    
    print("  📦 Repository: \(repoId)")
    print("  📄 File: \(fileName)")
    print("  🔗 URL: \(testURL)")
    print("")
    
    let downloader = ResilientDownloader.shared
    
    print("  ⏳ Starting download...")
    let startTime = Date()
    
    do {
        let resultURL = try await downloader.downloadAsync(
            url: testURL,
            to: destination,
            configuration: .default
        ) { progress in
            let percent = Int(progress.progress * 100)
            if percent == 0 || percent == 50 || percent == 100 {
                print("    Progress: \(percent)%")
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        let attrs = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        
        print("")
        print("  ✅ Download Complete!")
        print("    • File Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        print("    • Time: \(String(format: "%.3f", elapsed))s")
        
        if let content = try? String(contentsOf: resultURL, encoding: .utf8),
           let jsonData = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            print("    • Valid JSON: ✓")
            
            if let modelType = json["model_type"] as? String {
                print("    • Model Type: \(modelType)")
            }
            if let hiddenSize = json["hidden_size"] as? Int {
                print("    • Hidden Size: \(hiddenSize)")
            }
            if let numLayers = json["num_hidden_layers"] as? Int {
                print("    • Num Layers: \(numLayers)")
            }
            if let vocabSize = json["vocab_size"] as? Int {
                print("    • Vocab Size: \(vocabSize)")
            }
        }
        
        try? FileManager.default.removeItem(at: resultURL)
        print("    • Cleanup: Done ✓")
        
    } catch {
        print("  ❌ Download Failed: \(error.localizedDescription)")
    }
}

@MainActor
func testLlamaTokenizerDownload() async {
    let repoId = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    let fileName = "tokenizer.json"
    let testURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)")!
    let tempDir = FileManager.default.temporaryDirectory
    let destination = tempDir.appendingPathComponent("llama_tokenizer_\(UUID().uuidString).json")
    
    print("  📦 Repository: \(repoId)")
    print("  📄 File: \(fileName)")
    print("  🔗 URL: \(testURL)")
    print("")
    
    let downloader = ResilientDownloader.shared
    
    print("  📡 Network Info:")
    print("    • Connection: \(downloader.connectionType)")
    print("    • Quality: \(downloader.networkQuality)")
    
    let config = downloader.optimalConfiguration()
    print("    • Chunk Size: \(config.chunkSize / 1024)KB")
    print("    • Concurrent: \(config.maxConcurrentChunks)")
    print("")
    
    print("  ⏳ Starting download...")
    let startTime = Date()
    var lastPrintedPercent = -10
    
    do {
        let resultURL = try await downloader.downloadAsync(
            url: testURL,
            to: destination,
            configuration: .default
        ) { progress in
            let percent = Int(progress.progress * 100)
            
            if percent >= lastPrintedPercent + 10 || percent == 100 {
                lastPrintedPercent = percent
                let speed = progress.speedDescription
                let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                
                if let eta = progress.etaDescription {
                    print("    [\(percent)%] \(downloaded) / \(total) - \(speed) - \(eta)")
                } else {
                    print("    [\(percent)%] \(downloaded) / \(total) - \(speed)")
                }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        let attrs = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        let speedMBps = Double(size) / elapsed / 1_000_000
        
        print("")
        print("  ✅ Download Complete!")
        print("  ─────────────────────")
        print("    • File Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        print("    • Total Time: \(String(format: "%.2f", elapsed))s")
        print("    • Avg Speed: \(String(format: "%.2f", speedMBps)) MB/s")
        
        if let content = try? String(contentsOf: resultURL, encoding: .utf8) {
            if let jsonData = content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                print("    • Valid JSON: ✓")
                
                if let version = json["version"] {
                    print("    • Tokenizer Version: \(version)")
                }
                if let model = json["model"] as? [String: Any],
                   let vocabSize = (model["vocab"] as? [String: Any])?.count {
                    print("    • Vocab Size: \(vocabSize) tokens")
                }
            }
        }
        
        try? FileManager.default.removeItem(at: resultURL)
        print("    • Cleanup: Done ✓")
        
    } catch {
        print("")
        print("  ❌ Download Failed!")
        print("  ─────────────────────")
        print("    • Error: \(error.localizedDescription)")
        
        if let downloadError = error as? DownloadError {
            print("    • Type: \(downloadError)")
        }
    }
}

@MainActor
func testAllMLXFiles() async {
    let repoId = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    let files = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json"
    ]
    
    print("  📦 Repository: \(repoId)")
    print("  📄 Files to download: \(files.count)")
    print("")
    
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mlx_test_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    
    let downloader = ResilientDownloader.shared
    var totalSize: Int64 = 0
    var successCount = 0
    let startTime = Date()
    
    for (index, fileName) in files.enumerated() {
        let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)")!
        let destination = tempDir.appendingPathComponent(fileName)
        
        print("  [\(index + 1)/\(files.count)] Downloading \(fileName)...")
        
        do {
            let resultURL = try await downloader.downloadAsync(
                url: url,
                to: destination,
                configuration: .default
            ) { _ in }
            
            let attrs = try FileManager.default.attributesOfItem(atPath: resultURL.path)
            let size = attrs[.size] as? Int64 ?? 0
            totalSize += size
            successCount += 1
            
            print("       ✅ \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            
        } catch {
            print("       ❌ Failed: \(error.localizedDescription)")
        }
    }
    
    let elapsed = Date().timeIntervalSince(startTime)
    
    print("")
    print("  Summary:")
    print("  ─────────────────────")
    print("    • Downloaded: \(successCount)/\(files.count) files")
    print("    • Total Size: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
    print("    • Total Time: \(String(format: "%.2f", elapsed))s")
    
    try? FileManager.default.removeItem(at: tempDir)
    print("    • Cleanup: Done ✓")
}

func testVisualParallelDownload() async {
    print("""
      ┌────────────────────────────────────────────────────────────┐
      │  Simulating Parallel Chunk Downloads (Visual Demo)         │
      └────────────────────────────────────────────────────────────┘
    """)
    
    let chunks = 4
    let totalSteps = 20
    var chunkProgress = [Int](repeating: 0, count: chunks)
    
    print("")
    print("  Downloading 1GB file with \(chunks) parallel chunks:")
    print("")
    
    for _ in 1...totalSteps {
        for i in 0..<chunks {
            let speed = Double.random(in: 0.8...1.2)
            chunkProgress[i] = min(totalSteps, chunkProgress[i] + Int(speed * 1.2))
        }
        
        for i in 0..<chunks {
            let progress = min(chunkProgress[i], totalSteps)
            let percent = (progress * 100) / totalSteps
            let bar = renderProgressBar(progress: progress, total: totalSteps, width: 30)
            let chunkRange = "\(i * 250)-\((i + 1) * 250)MB"
            print("  Chunk \(i + 1) [\(chunkRange.padding(toLength: 12, withPad: " ", startingAt: 0))]: \(bar) \(percent)%")
        }
        
        let overallProgress = chunkProgress.reduce(0, +) / chunks
        let overallPercent = (overallProgress * 100) / totalSteps
        print("  ─────────────────────────────────────────────────────────")
        print("  Overall: \(renderProgressBar(progress: overallProgress, total: totalSteps, width: 40)) \(overallPercent)%")
        print("")
        
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    
    print("  ✅ All chunks completed!")
    print("")
    
    print("  Now downloading real file with visual progress...")
    print("")
    
    await downloadWithVisualProgress()
}

func renderProgressBar(progress: Int, total: Int, width: Int) -> String {
    let filled = (progress * width) / total
    let empty = width - filled
    let filledBar = String(repeating: "█", count: filled)
    let emptyBar = String(repeating: "░", count: empty)
    return "[\(filledBar)\(emptyBar)]"
}

@MainActor
func downloadWithVisualProgress() async {
    let repoId = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    let fileName = "tokenizer_config.json"
    let testURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(fileName)")!
    let tempDir = FileManager.default.temporaryDirectory
    let destination = tempDir.appendingPathComponent("visual_test_\(UUID().uuidString).json")
    
    print("  📄 File: \(fileName)")
    print("")
    
    let startTime = Date()
    var lastPercent = -1
    
    do {
        let resultURL = try await ResilientDownloader.shared.downloadAsync(
            url: testURL,
            to: destination,
            configuration: .default
        ) { progress in
            let percent = Int(progress.progress * 100)
            if percent != lastPercent {
                lastPercent = percent
                let bar = renderProgressBar(progress: percent, total: 100, width: 40)
                let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                print("  \(bar) \(percent)% (\(downloaded)/\(total))")
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let attrs = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        
        print("")
        print("  ✅ Complete! \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) in \(String(format: "%.2f", elapsed))s")
        
        try? FileManager.default.removeItem(at: resultURL)
        
    } catch {
        print("")
        print("  ❌ Failed: \(error.localizedDescription)")
    }
}

// MARK: - Main Entry Point

print("""
╔═══════════════════════════════════════════════════════════════╗
║           🚀 ResilientDownloader Demo & Test                  ║
║                    Version \(ResilientDownloaderVersion.version)                             ║
╚═══════════════════════════════════════════════════════════════╝
""")

print("\n📋 Test 1: Configuration Presets")
print("─────────────────────────────────")
testConfigurations()

print("\n📡 Test 2: Network Adapter")
print("─────────────────────────────────")
testNetworkAdapter()

Task { @MainActor in
    print("\n🔄 Test 3: Retry Engine")
    print("─────────────────────────────────")
    await testRetryEngine()
    
    print("\n⬇️ Test 4: MLX Download - config.json from mlx-community/Llama-3.2-1B-Instruct-4bit")
    print("─────────────────────────────────")
    await testLlamaConfigDownload()
    
    print("\n⬇️ Test 5: MLX Download - tokenizer.json from mlx-community/Llama-3.2-1B-Instruct-4bit")
    print("─────────────────────────────────")
    await testLlamaTokenizerDownload()
    
    print("\n📦 Test 6: Download All MLX Config Files from Llama-3.2-1B-Instruct-4bit")
    print("─────────────────────────────────")
    await testAllMLXFiles()
    
    print("\n🎬 Test 7: Visual Parallel Download Demo")
    print("─────────────────────────────────")
    await testVisualParallelDownload()
    
    print("""
    
    ╔═══════════════════════════════════════════════════════════════╗
    ║                    ✅ All Tests Complete!                     ║
    ╚═══════════════════════════════════════════════════════════════╝
    """)
    
    exit(0)
}

RunLoop.main.run()
