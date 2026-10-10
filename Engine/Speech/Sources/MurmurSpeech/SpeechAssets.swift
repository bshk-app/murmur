import Foundation
import HuggingFace

public enum SpeechAssets {
    /// Live-dictation snapshot. The previous check accepted any non-empty file, so a
    /// download cut 8.5 MB short loaded without an error and the live draft never appeared.
    static let nemotron = PinnedSnapshot(revision: "7279359e4481b5e9e185a318bd618e429c6d86cd", files: [
        .init(path: "config.json", bytes: 159_605, sha256: "f30c7bc469fc01fd5483172b4d7c75075030ddb60f347589c44e216b0a5ea9b6"),
        .init(path: "vocab.txt", bytes: 78_294, sha256: "d74b60edd1cad792cfce25dcb7e1048d78d717cf4f29acaae2854262d5189f4f"),
        .init(path: "model.safetensors", bytes: 755_598_923, sha256: "a64a4da048e7d28dde4cd4ff61ce59308a63314bb5563e73e06c24aae50ea941"),
    ])

    public static func prepareFastModel(onProgress: @escaping @MainActor @Sendable (Progress, String) -> Void = { _, _ in }) async throws {
        let name = SpeechSession.nemotronRepository
        guard let repo = Repo.ID(rawValue: name) else { throw URLError(.badURL) }
        let root = HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio")
            .appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !nemotron.isVerified(in: root) else { return }
        let stale = try nemotron.filesNeedingDownload(in: root)
        if !stale.isEmpty { try await download(stale, from: repo, into: root, onProgress: onProgress) }
        try nemotron.markVerified(in: root)
    }
    private static func download(_ files: [PinnedAsset], from repo: Repo.ID, into root: URL,
                                 onProgress: @escaping @MainActor @Sendable (Progress, String) -> Void) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7_200
        let transport = URLSession(configuration: configuration)
        defer { transport.finishTasksAndInvalidate() }
        // No Hub cache: its exact-revision fast path would keep returning a bad cached copy.
        let client = HubClient(session: transport, cache: nil)
        let overall = Progress(totalUnitCount: files.reduce(0) { $0 + Int64($1.bytes) })
        for file in files {
            // Unique per call: the app and the keyboard extension may fetch the same file at once.
            let staging = root.appendingPathComponent(".\(file.path).\(UUID().uuidString).download")
            defer { try? FileManager.default.removeItem(at: staging) }
            let resumeURL = root.appendingPathComponent(file.path + ".resume")
            let progress = Progress(totalUnitCount: -1)
            overall.addChild(progress, withPendingUnitCount: Int64(file.bytes))
            await onProgress(overall, file.path)
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    if let resumeData = try? Data(contentsOf: resumeURL) {
                        _ = try await client.resumeDownloadFile(resumeData: resumeData, to: staging, progress: progress)
                    } else {
                        _ = try await client.downloadFile(at: file.path, from: repo, to: staging, revision: nemotron.revision,
                                                          progress: progress, transport: .lfs)
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
            try file.install(staging, in: root)
        }
    }
}
