import CryptoKit
import Foundation

// Built by Scripts/test-model-integrity.sh together with PinnedAsset.swift and the vendored
// SafetensorsIntegrity.swift; MurmurSpeech itself cannot link into a test bundle.
// A live-model download cut 8.5 MB short passed the old "file is non-empty" checks, and the
// model then loaded garbage for its missing tensors and printed nothing.
@main struct ModelIntegrityChecks {
    nonisolated(unsafe) static var failures = 0

    static func main() throws {
        safetensorsChecks()
        weightDirectoryChecks()
        pinnedSnapshotChecks()
        // Optional real files: report each one so a cache can be audited by hand.
        for path in CommandLine.arguments.dropFirst() {
            print("\(SafetensorsIntegrity.isComplete(at: URL(fileURLWithPath: path)) ? "complete" : "INCOMPLETE")  \(path)")
        }
        print(failures == 0 ? "All model integrity checks passed" : "\(failures) model integrity check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func safetensorsChecks() {
        withDirectory { dir in
            check(SafetensorsIntegrity.isComplete(at: write(safetensors([16, 8]), to: dir, as: "a.safetensors")),
                  "complete safetensors is accepted")
            check(!SafetensorsIntegrity.isComplete(at: write(safetensors([16, 8]).dropLast(5), to: dir, as: "b.safetensors")),
                  "safetensors cut short is rejected")
            check(SafetensorsIntegrity.isComplete(at: write(safetensors([16]) + Data([0, 0]), to: dir, as: "c.safetensors")),
                  "trailing bytes do not force a re-download")
            check(!SafetensorsIntegrity.isComplete(at: write(Data(), to: dir, as: "d.safetensors")), "empty file is rejected")
            check(!SafetensorsIntegrity.isComplete(at: write(Data(repeating: 0xFF, count: 64), to: dir, as: "e.safetensors")),
                  "noise is rejected")
            check(!SafetensorsIntegrity.isComplete(at: write(forgedOffset(), to: dir, as: "f.safetensors")),
                  "forged huge offset is rejected without overflow")
            check(!SafetensorsIntegrity.isComplete(at: dir.appendingPathComponent("missing.safetensors")), "missing file is rejected")
        }
    }

    static func weightDirectoryChecks() {
        withDirectory { dir in
            write(Data("{}".utf8), to: dir, as: "config.json")
            check(!SafetensorsIntegrity.hasCompleteWeights(in: dir, requiredExtension: "safetensors"),
                  "directory without weights is incomplete")
            write(safetensors([8]), to: dir, as: "model-00001-of-00002.safetensors")
            check(SafetensorsIntegrity.hasCompleteWeights(in: dir, requiredExtension: "safetensors"),
                  "directory with complete weights is accepted")
            write(safetensors([8]).dropLast(1), to: dir, as: "model-00002-of-00002.safetensors")
            check(!SafetensorsIntegrity.hasCompleteWeights(in: dir, requiredExtension: "safetensors"),
                  "one truncated shard makes the directory incomplete")
        }
    }

    static func pinnedSnapshotChecks() {
        let content = Data("pinned weights".utf8)
        let asset = PinnedAsset(path: "model.safetensors", bytes: content.count, sha256: sha256(content))
        let snapshot = PinnedSnapshot(revision: "a", files: [asset])
        func needs(_ dir: URL) -> [String] { ((try? snapshot.filesNeedingDownload(in: dir)) ?? []).map(\.path) }

        withDirectory { dir in
            check(needs(dir) == ["model.safetensors"], "missing file is downloaded")
            write(content.dropLast(3), to: dir, as: "model.safetensors")
            check(needs(dir) == ["model.safetensors"], "truncated file is downloaded again")
            write(Data(repeating: 0, count: content.count), to: dir, as: "model.safetensors")
            check(needs(dir) == ["model.safetensors"], "same-size altered file is downloaded again")
            write(content, to: dir, as: "model.safetensors")
            check(needs(dir).isEmpty, "intact file is kept")
        }
        withDirectory { dir in
            let model = write(content, to: dir, as: "model.safetensors")
            check(!snapshot.isVerified(in: dir), "no marker means not verified")
            try? snapshot.markVerified(in: dir)
            check(snapshot.isVerified(in: dir), "marker with matching sizes is verified")
            check(!PinnedSnapshot(revision: "b", files: [asset]).isVerified(in: dir), "marker for another revision does not count")
            try? content.dropLast().write(to: model)
            check(!snapshot.isVerified(in: dir), "marker does not cover a file whose size changed")
            _ = needs(dir)
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(PinnedSnapshot.marker).path),
                  "re-hashing drops the marker until the snapshot is verified again")
        }
        withDirectory { dir in
            let download = write(content, to: dir, as: ".model.safetensors.download")
            write(content.dropLast(3), to: dir, as: "model.safetensors")
            check((try? asset.install(download, in: dir)) != nil, "verified download installs")
            check((try? Data(contentsOf: dir.appendingPathComponent("model.safetensors"))) == content, "installed file replaces the bad one")
            check(!FileManager.default.fileExists(atPath: download.path), "installed download is moved, not copied")
        }
        withDirectory { dir in
            let download = write(content.dropLast(3), to: dir, as: ".model.safetensors.download")
            check((try? asset.install(download, in: dir)) == nil, "corrupt download is rejected")
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path),
                  "corrupt download never reaches the model path")
            check(!FileManager.default.fileExists(atPath: download.path), "corrupt download is deleted")
        }
    }

    static func check(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL")  \(name)")
    }

    static func withDirectory(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-integrity-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        body(dir)
    }

    @discardableResult
    static func write(_ data: Data, to dir: URL, as name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal safetensors: little-endian u64 header length, JSON header, packed tensor bytes.
    static func safetensors(_ tensorBytes: [Int]) -> Data {
        var offset = 0
        var entries = [#""__metadata__":{"format":"mlx"}"#]
        for (index, count) in tensorBytes.enumerated() {
            entries.append(#""t\#(index)":{"dtype":"U8","shape":[\#(count)],"data_offsets":[\#(offset),\#(offset + count)]}"#)
            offset += count
        }
        return framed(Data("{\(entries.joined(separator: ","))}".utf8)) + Data(repeating: 7, count: offset)
    }

    static func forgedOffset() -> Data {
        framed(Data(#"{"t":{"dtype":"U8","shape":[1],"data_offsets":[0,18446744073709551615]}}"#.utf8)) + Data([7])
    }

    static func framed(_ header: Data) -> Data {
        var length = UInt64(header.count).littleEndian
        return Data(bytes: &length, count: 8) + header
    }
}
