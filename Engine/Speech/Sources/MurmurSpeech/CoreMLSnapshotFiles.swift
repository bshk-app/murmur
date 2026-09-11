import MurmurCore
import HuggingFace

/// Exact files needed by the phone's split Core ML Parakeet pipeline.
/// Hub tree listings contain directories as well as files.
enum CoreMLSnapshotFiles {
    static func select(from entries: [Git.TreeEntry], encoder: String) -> [String] {
        let roots = [encoder, "Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]
        let files = entries.filter { entry in
            entry.type == .file && (
                entry.path == "parakeet_vocab.json" || roots.contains { entry.path.hasPrefix($0 + "/") }
            )
        }.map(\.path)
        return Array(Set(files)).sorted()
    }
}
