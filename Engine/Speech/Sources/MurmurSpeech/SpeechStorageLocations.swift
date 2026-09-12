import Foundation
import MurmurCore
import HuggingFace

extension SpeechAssets {
    /// Only this iOS app's own SDK caches; never a desktop user's global HF cache.
    public static func storageLocations() -> [ModelStorageLocation] {
        #if os(iOS)
        let cache=HubCache.default
        let root=cache.cacheDirectory
        let home=URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath().path
        guard root.resolvingSymlinksInPath().path.hasPrefix(home + "/") else { return [] }
        var locations: [ModelStorageLocation] = []
        func addRepo(_ name: String, id: String, title: String, detail: String, markers: [URL] = [], invalidatedBy: [String] = []) {
            guard let repo=Repo.ID(rawValue:name) else { return }
            locations.append(.init(id:id,root:root,directory:cache.repoDirectory(repo:repo,kind:.model),title:title,detail:detail,markers:markers,invalidatedBy:invalidatedBy))
        }
        let readiness=root.appendingPathComponent("murmur-coreml-readiness")
        addRepo(GigaAMCorrector.repo,id:"speech/russian-accurate",title:"Russian speech recognition",detail:"Used for Russian dictation and audio imports.",markers:[readiness.appendingPathComponent("ready-gigaam-"+GigaAMCorrector.revision)])
        addRepo(SpeechSession.coreMLRepo,id:"speech/multilingual-accurate",title:"Multilingual speech recognition",detail:"Shared by several dictation languages and keyboard sessions.",markers:["Encoder.mlmodelc","EncoderInt4.mlmodelc"].map { readiness.appendingPathComponent("ready-"+$0+"-"+SpeechSession.coreMLRevision) })
        for (repo,id,title) in [(SpeechSession.nemotronRepository,"speech/live","Live dictation"),(SpeechBoundaryDetector.defaultRepo,"speech/detection-live","Speech detection for live dictation")] {
            let directory=root.appendingPathComponent("mlx-audio").appendingPathComponent(repo.replacingOccurrences(of:"/",with:"_"))
            let snapshots = Repo.ID(rawValue:repo).map { [cache.repoDirectory(repo:$0,kind:.model)] } ?? []
            locations.append(.init(id:id,root:root,directory:directory,title:title,detail:"A shared component. Deleting it affects every mode that uses it.",additionalDirectories:snapshots))
        }
        for choice in [SpeechModelChoice.cohere, .cohereArabic, .whisper] {
            guard let source=try? PhoneMLXCorrector.modelSource(for:choice) else { continue }
            addRepo(source.name,id:"speech/additional-"+choice.rawValue,title:choice == .cohereArabic ? "Arabic speech recognition" : choice.title,detail:"A shared component. Deleting it affects every mode that uses it.",markers:[root.appendingPathComponent("murmur-mlx-readiness").appendingPathComponent(source.revision)],invalidatedBy:["imported/ASRModels/"+choice.rawValue])
        }
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        if let repo = Repo.ID(rawValue: CanaryAssets.repository) {
            locations.append(.init(id: "speech/canary", root: URL(fileURLWithPath: home),
                directory: CanaryAssets.defaultDirectory, title: "Canary experiment",
                detail: "Used by experimental speech recognition and translation.",
                additionalDirectories: [cache.repoDirectory(repo: repo, kind: .model)]))
        }
        let fluid=support.appendingPathComponent("FluidAudio")
        locations.append(.init(id:"speech/detection-files",root:fluid,directory:fluid.appendingPathComponent("Models"),title:"Speech detection for recordings",detail:"Used by audio imports and keyboard dictation."))
        return locations
        #else
        return []
        #endif
    }
}
