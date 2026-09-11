import Foundation
import HuggingFace

public enum SpeechAssets {
    public static func prepareFastModel(onProgress: @escaping @MainActor @Sendable (Progress, String) -> Void = { _, _ in }) async throws {
        let name = SpeechSession.nemotronRepository
        guard let repo = Repo.ID(rawValue: name) else { throw URLError(.badURL) }
        let root = HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio")
            .appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7_200
        let transport = URLSession(configuration: configuration)
        defer { transport.finishTasksAndInvalidate() }
        let client = HubClient(session: transport, cache: .default)
        let filenames = ["config.json", "vocab.txt", "model.safetensors"]
        let missing = filenames.filter { ((try? root.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 }
        guard !missing.isEmpty else { return }
        let entries = try await client.listFiles(in: repo, kind: .model, recursive: false)
        let sizes = Dictionary(uniqueKeysWithValues: entries.filter { filenames.contains($0.path) }.map { ($0.path, Int64($0.size ?? 0)) })
        let known = filenames.allSatisfy { (sizes[$0] ?? 0) > 0 }
        let overall = Progress(totalUnitCount: known ? filenames.reduce(0) { $0 + (sizes[$1] ?? 0) } : -1)
        for filename in filenames {
            let destination = root.appendingPathComponent(filename)
            let weight = sizes[filename] ?? 0
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                if known { overall.completedUnitCount += weight }
                continue
            }
            let resumeURL = root.appendingPathComponent(filename + ".resume")
            let progress = Progress(totalUnitCount: -1)
            if known { overall.addChild(progress, withPendingUnitCount: weight) }
            await onProgress(overall, filename)
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    if let resumeData = try? Data(contentsOf: resumeURL) {
                        _ = try await client.resumeDownloadFile(resumeData: resumeData, to: destination, progress: progress)
                    } else {
                        _ = try await client.downloadFile(at: filename, from: repo, to: destination, progress: progress, transport: .lfs)
                    }
                    if FileManager.default.fileExists(atPath: resumeURL.path) { try FileManager.default.removeItem(at: resumeURL) }
                    break
                } catch {
                    let nsError = error as NSError
                    if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        try resumeData.write(to: resumeURL, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: resumeURL.path) {
                        try FileManager.default.removeItem(at: resumeURL)
                    }
                    let retryable = nsError.domain == NSURLErrorDomain && [
                        URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue,
                        URLError.notConnectedToInternet.rawValue, URLError.cannotConnectToHost.rawValue,
                        URLError.cannotFindHost.rawValue,
                    ].contains(nsError.code)
                    guard retryable, attempt < 2 else { throw error }
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }

    }

}
