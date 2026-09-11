#if targetEnvironment(simulator)
import SwiftUI
import SafariServices

@main
struct PageTranslationTestHost: App {
    var body: some Scene { WindowGroup { PageTranslationTestHome() } }
}

private struct PageTranslationTestHome: View {
    @State private var status = "Fixture not prepared"
    @State private var preparing = false
    @State private var ready = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Safari integration test host").font(.title2)
                Text("Real English ↔ Finnish translation packages. This simulator host only prepares model storage and opens Safari.")
                Button("Prepare test models") { prepare() }
                    .accessibilityIdentifier("page-fixture-seed").disabled(preparing)
                Text(status).accessibilityIdentifier("page-fixture-status")
                if #available(iOS 18.4, *) {
                    Button("Default apps settings") {
                        guard let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }.accessibilityIdentifier("page-default-apps-settings")
                }
                if #available(iOS 26.2, *) {
                    Button("Safari extension settings") {
                        SFSafariSettings.openExtensionsSettings(forIdentifiers: ["app.bshk.murmur.ios.safari-translation"]) { error in
                            if let error { status = "Settings: " + error.localizedDescription }
                        }
                    }.accessibilityIdentifier("page-safari-settings")
                }
                Button("Open small page in Safari") { open("/small") }
                    .accessibilityIdentifier("open-page-small").disabled(!ready)
                Button("Open long page in Safari") { open("/long") }
                    .accessibilityIdentifier("open-page-long").disabled(!ready)
                Spacer()
            }.padding().navigationTitle("Murmator Page Tests")
        }.task {
            if ProcessInfo.processInfo.arguments.contains("--test-fixture") { prepare() }
        }
    }

    private func prepare() {
        guard !preparing else { return }
        preparing = true
        status = "Preparing English and Finnish packages…"
        Task {
            do {
                let copied = try await Task.detached(priority: .userInitiated) { try PageFixtureSeeder.seed() }.value
                TranslationPreferences.save(source: "en", target: "fi")
                status = "READY: English → Finnish (\(copied) packages copied)"
                ready = true
            } catch {
                status = "ERROR: " + error.localizedDescription
            }
            preparing = false
        }
    }

    private func open(_ path: String) {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--fixture-page-url"), arguments.indices.contains(i + 1),
           let url = URL(string: arguments[i + 1]), ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url); return
        }
        var origin = "http://127.0.0.1:18765"
        if let i = arguments.firstIndex(of: "--fixture-server"), arguments.indices.contains(i + 1) {
            origin = arguments[i + 1]
        }
        guard var components = URLComponents(string: origin + path) else { return }
        components.queryItems = [URLQueryItem(name: "visit", value: UUID().uuidString)]
        if arguments.contains("--fixture-finnish") { components.queryItems?.append(URLQueryItem(name: "lang", value: "fi")) }
        guard let url = components.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        UIApplication.shared.open(url)
    }
}

private enum PageFixtureSeeder {
    static func seed() throws -> Int {
        let files = FileManager.default
        guard let shared = files.containerURL(forSecurityApplicationGroupIdentifier: TranslationPaths.group) else {
            throw failure("Translation App Group unavailable. Sign the simulator host with TranslationProvider.entitlements.")
        }
        let models = shared.appendingPathComponent("TranslationModels", isDirectory: true)
        try files.createDirectory(at: models, withIntermediateDirectories: true)
        var copied = 0
        for name in ["ct2-enfi", "ct2-fien", "ct2-firu"] {
            let destination = models.appendingPathComponent(name, isDirectory: true)
            // Existing packages belong to the app/user and are never replaced.
            if files.fileExists(atPath: destination.path) {
                try validate(destination)
                continue
            }
            let source = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.resourceURL?.appendingPathComponent("TranslationModels/" + name)
            guard let source, files.fileExists(atPath: source.path) else {
                throw failure("Missing bundled fixture package: " + name)
            }
            try validate(source)
            let staging = models.appendingPathComponent(".page-fixture-" + UUID().uuidString, isDirectory: true)
            do {
                try files.copyItem(at: source, to: staging)
                try files.moveItem(at: staging, to: destination)
                copied += 1
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
        }
        let marker = shared.appendingPathComponent("translation-store-ready")
        if !files.fileExists(atPath: marker.path) { try Data("1".utf8).write(to: marker, options: .atomic) }
        return copied
    }

    private static func validate(_ directory: URL) throws {
        for name in ["model.bin", "config.json", "source.spm", "target.spm"] {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw failure("Incomplete fixture package: " + directory.lastPathComponent + "/" + name)
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MurmatorPageTestFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#else
#error("The page translation test host must never be built for a physical device or distributed.")
#endif
