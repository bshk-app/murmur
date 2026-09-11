import UIKit
import UniformTypeIdentifiers

/// A non-UI Share action: hand off the user's request, then return to Safari.
/// The Web Extension owns progress and inference while the page stays readable.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) else {
            context.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
            Task { @MainActor in
                var payload: [String: Any] = [
                    "action": "setup",
                    "message": PageL10n.text("Start from Safari’s page menu → Murmator. Allow website access if asked."),
                    "openApp": PageL10n.text("Open Murmator"),
                    "close": PageL10n.text("Close")
                ]
                if let dictionary = item as? [String: Any],
                   let metadata = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let url = metadata["url"] as? String, url.utf16.count <= 16_384 {
                    if !TranslationPaths.isReady {
                        payload["message"] = PageL10n.text("Open Murmator once before translating webpages.")
                    } else if metadata["extensionAvailable"] as? Bool == true {
                        do {
                            payload["ticket"] = try SafariTranslationHandoff.create(pageURL: url)
                            payload["action"] = "start"
                        } catch {
                            payload["message"] = PageL10n.text("Could not start page translation. Try again from Share.")
                        }
                    }
                } else {
                    payload["message"] = PageL10n.text("This action needs a Safari webpage.")
                }
                let result = NSExtensionItem()
                result.attachments = [NSItemProvider(item: [NSExtensionJavaScriptFinalizeArgumentKey: payload] as NSDictionary, typeIdentifier: UTType.propertyList.identifier)]
                context.completeRequest(returningItems: [result], completionHandler: nil)
            }
        }
    }
}
