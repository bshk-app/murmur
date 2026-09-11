import UIKit
import SwiftUI
import UniformTypeIdentifiers
import MurmurCore

final class ActionViewController: UIViewController {
    private let state = PageTranslationState()
    private var completed = false
    override func viewDidLoad() {
        super.viewDidLoad()
        setenv("CT2_MMAP_WEIGHTS", "1", 1)
        state.finish = { [weak self] page, output, source, target in self?.complete(page, output, source, target) }
        state.dismiss = { [weak self] in self?.cancel() }
        let host = UIHostingController(rootView: PageTranslationView(state: state))
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor), host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) else {
            state.phase = .idle; state.error = PageL10n.text("This action needs a Safari webpage."); return
        }
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                guard let self, !self.completed else { return }
                do {
                    guard let dictionary = item as? [String: Any], let payload = dictionary[NSExtensionJavaScriptPreprocessingResultsKey], JSONSerialization.isValidJSONObject(payload) else { throw PageTranslationError.invalidPage }
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    guard data.count <= 3_000_000 else { throw PageTranslationError.pageTooLarge }
                    self.state.receive(try JSONDecoder().decode(PageTranslationRequest.self, from: data))
                } catch { self.state.phase = .idle; self.state.show(error) }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !completed, isBeingDismissed || navigationController?.isBeingDismissed == true { state.cancel() }
    }
    private func complete(_ page: PageTranslationRequest, _ output: PageTranslationOutput, _ source: String, _ target: String) {
        guard !completed else { return }; completed = true
        let labels = ["translated": PageL10n.format("Translation into %@", state.name(target)), "showOriginal": PageL10n.text("Show original"), "showTranslation": PageL10n.text("Show translation"), "close": PageL10n.text("Close"), "changedPage": PageL10n.text("Some page content changed and was left unchanged."), "partial": PageL10n.text("Some page content changed and was left unchanged.")]
        let payload: [String: Any] = ["version": 1, "runId": page.runId, "action": "apply", "source": source, "target": target, "translations": output.translations.map { ["id": $0.id, "text": $0.text] }, "fallbackGroups": output.fallbackGroups, "labels": labels]
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: [NSExtensionJavaScriptFinalizeArgumentKey: payload] as NSDictionary, typeIdentifier: UTType.propertyList.identifier)]
        extensionContext?.completeRequest(returningItems: [item], completionHandler: nil)
    }
    private func cancel() {
        guard !completed else { return }; completed = true
        // Complete the Safari JavaScript round trip on cancellation too. This
        // clears its pending snapshot and releases the page's script session.
        var items: [NSExtensionItem] = []
        if let page = state.page {
            let item = NSExtensionItem()
            let payload: [String: Any] = ["version": 1, "runId": page.runId, "action": "cancel"]
            item.attachments = [NSItemProvider(item: [NSExtensionJavaScriptFinalizeArgumentKey: payload] as NSDictionary, typeIdentifier: UTType.propertyList.identifier)]
            items.append(item)
        }
        extensionContext?.completeRequest(returningItems: items, completionHandler: nil)
    }
}
