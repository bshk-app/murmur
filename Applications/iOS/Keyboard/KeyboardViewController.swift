import UIKit
import SwiftUI
import MurmurCore

private final class KeyboardStatusLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 8, dy: 4)) }
    override var intrinsicContentSize: CGSize { let size = super.intrinsicContentSize; return CGSize(width: size.width + 16, height: size.height + 8) }
}

private final class HoldToTalkButton: UIButton {
    var accessibilityToggle: (() -> Void)?
    override func accessibilityActivate() -> Bool { accessibilityToggle?(); return true }
}

/// The extension owns controls and insertion only. Audio and inference remain
/// in the containing app's explicitly enabled background microphone session.
final class KeyboardViewController: UIInputViewController, UITextViewDelegate {
    #if MURMUR_UI_HOST
    // Only the separate design/test host can stage a visual keyboard state.
    // No microphone, engine or App Group commands are involved in these images.
    private var designSnapshot: KeyboardSessionState?
    private var designHandledID: UUID?
    override var hasFullAccess: Bool { true }
    func setDesignSnapshot(_ value: KeyboardSessionState, handledID: UUID? = nil) {
        designSnapshot = value; designHandledID = handledID; configuration = value.configuration
        loadViewIfNeeded(); lastInserted = handledID; refreshMenus(); refresh()
    }
    #endif
    private let preview = UITextView()
    private let previewBeginning = UIButton(type: .system)
    private let previewEnd = UIButton(type: .system)
    private var previewUtterance: UUID?
    private var previewFinal = false
    private var followsPreview = true
    private let status = KeyboardStatusLabel()
    private let hint = UILabel()
    private let resultCard = UIStackView()
    private let clearResultButton = UIButton(type: .system)
    private let languageRow = UIStackView()
    private let insertionRow = UIStackView()
    private let insertOriginal = UIButton(type: .system)
    private let preparationSpinner = UIActivityIndicatorView(style: .medium)
    private let talk = HoldToTalkButton(type: .system)
    private let sourceButton = UIButton(type: .system)
    private let translationButton = UIButton(type: .system)
    private let insertResult = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)
    private var openHost: UIHostingController<KeyboardActivationLink>?
    private var timer: Timer?
    private var deleteTimer: Timer?
    private var visible = false
    private var holding = false
    private var awaitingStart = false
    private var stopWhenStarted = false
    private var autoInsertID: UUID?
    private var requestedUtterance: UUID?
    private var anchor: KeyboardInsertionAnchor?
    private var lastHeartbeat = Date.distantPast
    private var localError: String?
    private var state: KeyboardSessionState?
    private var configuration = KeyboardConfiguration()
    private var lastInserted: UUID?
    private var activationTitle = "Activate in Murmator"
    private var editRevision: UInt64 = 0
    private let accent = UIColor(red: 224/255, green: 122/255, blue: 47/255, alpha: 1)
    private var paletteDark: Bool { traitCollection.userInterfaceStyle == .dark }
    private var ink: UIColor { UIColor { traits in traits.userInterfaceStyle == .dark ? .white : UIColor(red: 0.16, green: 0.14, blue: 0.12, alpha: 1) } }
    private var card: UIColor { UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.09) : UIColor.black.withAlphaComponent(0.05) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        inputView?.allowsSelfSizing = true
        configuration = KeyboardSessionStore.configuration ?? .init()
        lastInserted = KeyboardSessionStore.insertedID
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 270)
        ])
        let header = UIStackView(); header.spacing = 10; header.alignment = .center
        let mascot = UIImageView(image: UIImage(named: "MascotMark")); mascot.contentMode = .scaleAspectFit
        mascot.widthAnchor.constraint(equalToConstant: 22).isActive = true; mascot.heightAnchor.constraint(equalToConstant: 22).isActive = true
        header.addArrangedSubview(mascot)
        let title = UILabel(); title.text = "Murmator"; title.font = .preferredFont(forTextStyle: .headline); title.textColor = ink
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal); header.addArrangedSubview(title)
        status.font = .preferredFont(forTextStyle: .caption1); status.textColor = .secondaryLabel; status.numberOfLines = 2; status.textAlignment = .center; status.layer.cornerRadius = 6; status.clipsToBounds = true
        header.addArrangedSubview(status)
        endButton.titleLabel?.font = .preferredFont(forTextStyle: .caption2); endButton.titleLabel?.numberOfLines = 2; endButton.tintColor = .secondaryLabel
        endButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; endButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        endButton.accessibilityLabel = L10n.text("Turn off microphone"); endButton.accessibilityIdentifier = "keyboard-end-session"
        endButton.addTarget(self, action: #selector(endSession), for: .touchUpInside); header.addArrangedSubview(endButton); stack.addArrangedSubview(header)
        let languages = languageRow; languages.spacing = 9; languages.distribution = .fillEqually
        for button in [sourceButton, translationButton] { button.tintColor = ink; button.backgroundColor = card; button.layer.cornerRadius = 11; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true; button.showsMenuAsPrimaryAction = true; languages.addArrangedSubview(button) }
        sourceButton.accessibilityIdentifier = "keyboard-source-language"; translationButton.accessibilityIdentifier = "keyboard-translation-language"
        stack.addArrangedSubview(languages)
        preview.font = .preferredFont(forTextStyle: .subheadline); preview.textColor = ink
        preview.adjustsFontForContentSizeCategory = true
        preview.isEditable = false; preview.isSelectable = true; preview.isScrollEnabled = true
        preview.backgroundColor = .clear; preview.textContainerInset = .zero
        preview.textContainer.lineFragmentPadding = 0; preview.textContainer.lineBreakMode = .byWordWrapping
        preview.delegate = self
        preview.accessibilityIdentifier = "keyboard-live-text"; preview.heightAnchor.constraint(equalToConstant: 110).isActive = true
        resultCard.axis = .vertical; resultCard.spacing = 7; resultCard.isLayoutMarginsRelativeArrangement = true
        resultCard.layoutMargins = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14); resultCard.layer.cornerRadius = 14
        let resultTitle = UILabel(); resultTitle.text = L10n.text("Result"); resultTitle.font = .preferredFont(forTextStyle: .caption2); resultTitle.textColor = .secondaryLabel
        let resultHeader = UIStackView(); resultHeader.alignment = .center; resultHeader.spacing = 8
        resultHeader.heightAnchor.constraint(equalToConstant: 44).isActive = true
        previewBeginning.setImage(UIImage(systemName: "arrow.up.to.line"), for: .normal)
        previewEnd.setImage(UIImage(systemName: "arrow.down.to.line"), for: .normal)
        for button in [previewBeginning, previewEnd] {
            button.tintColor = ink
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        previewBeginning.accessibilityLabel = L10n.text("Beginning"); previewBeginning.accessibilityIdentifier = "keyboard-text-beginning"
        previewEnd.accessibilityLabel = L10n.text("End"); previewEnd.accessibilityIdentifier = "keyboard-text-end"
        previewBeginning.addTarget(self, action: #selector(readPreviewBeginning), for: .touchUpInside)
        previewEnd.addTarget(self, action: #selector(readPreviewEnd), for: .touchUpInside)
        clearResultButton.setTitle(L10n.text("Clear"), for: .normal); clearResultButton.tintColor = ink
        clearResultButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        clearResultButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearResultButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        clearResultButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        clearResultButton.setContentHuggingPriority(.required, for: .horizontal)
        clearResultButton.accessibilityIdentifier = "keyboard-clear-result"
        clearResultButton.addTarget(self, action: #selector(clearCurrentResult), for: .touchUpInside)
        resultHeader.addArrangedSubview(resultTitle); resultHeader.addArrangedSubview(previewBeginning); resultHeader.addArrangedSubview(previewEnd); resultHeader.addArrangedSubview(clearResultButton)
        resultCard.addArrangedSubview(resultHeader); resultCard.addArrangedSubview(preview); stack.addArrangedSubview(resultCard)
        hint.font = .preferredFont(forTextStyle: .footnote); hint.textColor = .secondaryLabel; hint.numberOfLines = 3
        stack.addArrangedSubview(hint)
        preparationSpinner.hidesWhenStopped = true; preparationSpinner.color = accent
        stack.addArrangedSubview(preparationSpinner)
        talk.setTitle(L10n.text("Hold to talk"), for: .normal); talk.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        talk.tintColor = .black; talk.backgroundColor = accent; talk.layer.cornerRadius = 15; talk.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        talk.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true; talk.accessibilityIdentifier = "keyboard-hold-to-talk"
        talk.addTarget(self, action: #selector(pressBegan), for: .touchDown)
        talk.addTarget(self, action: #selector(pressEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        talk.accessibilityToggle = { [weak self] in
            guard let self else { return }
            if self.state?.phase == .recording { self.pressEnded() } else { self.pressBegan() }
        }
        stack.addArrangedSubview(talk)
        let link = UIHostingController(rootView: KeyboardActivationLink(title: "Activate in Murmator"))
        addChild(link); link.view.backgroundColor = .clear; link.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        stack.addArrangedSubview(link.view); link.didMove(toParent: self); openHost = link
        insertResult.setTitle(L10n.text("Insert text"), for: .normal); insertResult.tintColor = .black; insertResult.backgroundColor = accent; insertResult.layer.cornerRadius = 15; insertResult.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        insertResult.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true; insertResult.accessibilityIdentifier = "keyboard-insert-result"
        insertResult.addTarget(self, action: #selector(insertCurrentResult), for: .touchUpInside)
        insertOriginal.setTitle(L10n.text("Insert original"), for: .normal); insertOriginal.tintColor = ink; insertOriginal.backgroundColor = card; insertOriginal.layer.cornerRadius = 13
        for button in [talk, insertResult, insertOriginal] { button.titleLabel?.numberOfLines = 0; button.titleLabel?.textAlignment = .center; button.titleLabel?.adjustsFontForContentSizeCategory = true }
        insertOriginal.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        insertOriginal.addTarget(self, action: #selector(insertOriginalResult), for: .touchUpInside)
        insertionRow.axis = .horizontal; insertionRow.distribution = .fillEqually; insertionRow.spacing = 9
        insertionRow.addArrangedSubview(insertResult); insertionRow.addArrangedSubview(insertOriginal)
        stack.addArrangedSubview(insertionRow)
        let row = UIStackView(); row.distribution = .fill; row.spacing = 12
        let globe = UIButton(type: .system); globe.setImage(UIImage(systemName: "globe"), for: .normal); globe.accessibilityLabel = L10n.text("Next keyboard")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let back = UIButton(type: .system); back.setImage(UIImage(systemName: "delete.left"), for: .normal); back.accessibilityLabel = L10n.text("Delete character"); back.accessibilityIdentifier = "keyboard-delete"
        back.addTarget(self, action: #selector(backspace), for: .touchUpInside)
        back.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
        sendButton.accessibilityIdentifier = "keyboard-send"; sendButton.addTarget(self, action: #selector(sendReturn), for: .touchUpInside)
        for button in [globe, back, sendButton] { button.tintColor = ink; button.backgroundColor = card; button.layer.cornerRadius = 10; button.heightAnchor.constraint(equalToConstant: 44).isActive = true; row.addArrangedSubview(button) }
        back.widthAnchor.constraint(equalTo: globe.widthAnchor).isActive = true
        sendButton.widthAnchor.constraint(equalTo: globe.widthAnchor, multiplier: 1.4).isActive = true
        stack.addArrangedSubview(row)
        let flexibleSpace = UIView()
        flexibleSpace.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        flexibleSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        stack.addArrangedSubview(flexibleSpace)
        for label in [status, hint, title] { label.adjustsFontForContentSizeCategory = true }
        refreshMenus(); refresh()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); visible = true; localError = nil
        configuration = KeyboardSessionStore.configuration ?? configuration; refreshMenus()
        #if MURMUR_UI_HOST
        lastInserted = designHandledID
        #else
        lastInserted = KeyboardSessionStore.insertedID
        #endif
        refresh()
        timer?.invalidate()
        let next = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    override func viewWillDisappear(_ animated: Bool) {
        if awaitingStart { send(.cancel, utterance: requestedUtterance); awaitingStart = false; holding = false }
        else if holding { pressEnded() }
        visible = false; autoInsertID = nil; anchor = nil
        timer?.invalidate(); timer = nil; deleteTimer?.invalidate(); deleteTimer = nil
        super.viewWillDisappear(animated)
    }
    override func textDidChange(_ textInput: UITextInput?) { super.textDidChange(textInput); editRevision &+= 1; updateReturnKey() }
    override func selectionDidChange(_ textInput: UITextInput?) { super.selectionDidChange(textInput); editRevision &+= 1; updateReturnKey() }
    private func currentAnchor() -> KeyboardInsertionAnchor {
        .init(documentID: textDocumentProxy.documentIdentifier, before: textDocumentProxy.documentContextBeforeInput,
              after: textDocumentProxy.documentContextAfterInput, selection: textDocumentProxy.selectedText, editRevision: editRevision)
    }
    private var readySession: Bool {
        guard hasFullAccess, let state else { return false }
        return state.presentation(for: configuration, hasFullAccess: hasFullAccess) == .ready
    }
    @objc private func pressBegan() {
        guard readySession, let state, state.phase == .ready || state.phase == .result, !awaitingStart else { return }
        localError = nil; holding = true; awaitingStart = true; stopWhenStarted = false; autoInsertID = nil
        anchor = currentAnchor()
        requestedUtterance = UUID()
        send(.start, utterance: requestedUtterance)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    @objc private func pressEnded() {
        holding = false
        if awaitingStart { stopWhenStarted = true; return }
        guard let state, state.phase == .recording else { return }
        autoInsertID = visible ? state.utteranceID : nil
        send(.stop)
    }
    private func send(_ action: KeyboardCommand.Action, utterance: UUID? = nil) {
        guard hasFullAccess, let state else { return }
        do { try KeyboardSessionStore.send(.init(sessionID: state.sessionID, utteranceID: utterance ?? state.utteranceID, action: action)) }
        catch { localError = L10n.text("Could not update the keyboard. Open Murmator and try again."); awaitingStart = false; holding = false }
    }
    private func refresh() {
        #if MURMUR_UI_HOST
        state = designSnapshot
        state?.updatedAt = Date()
        if let state { configuration = state.configuration }
        #else
        if let requested = KeyboardSessionStore.configuration, requested != configuration {
            configuration = requested; refreshMenus()
        }
        state = KeyboardSessionStore.state
        #endif
        view.backgroundColor = paletteDark ? UIColor(red: 28/255, green: 23/255, blue: 20/255, alpha: 1) : UIColor(red: 230/255, green: 224/255, blue: 214/255, alpha: 1)
        let ready = readySession
        let presentation = state?.presentation(for: configuration, hasFullAccess: hasFullAccess) ?? .activationRequired
        #if !MURMUR_UI_HOST
        if visible, hasFullAccess, let state, state.isFresh(), state.microphoneActive, Date().timeIntervalSince(lastHeartbeat) > 2 {
            do { try KeyboardSessionStore.keepAlive(state.sessionID); lastHeartbeat = Date() } catch { localError = L10n.text("Full Access is required for keyboard dictation.") }
        }
        #endif
        if awaitingStart, state?.phase == .recording, ready {
            awaitingStart = false
            if stopWhenStarted { stopWhenStarted = false; pressEnded() }
        }
        if !ready { holding = false; awaitingStart = false; stopWhenStarted = false; autoInsertID = nil }
        let phase = state?.phase ?? .inactive
        let title = presentation == .resumePreparation ? "Open Murmator" : "Activate in Murmator"
        if activationTitle != title { activationTitle = title; openHost?.rootView = KeyboardActivationLink(title: LocalizedStringKey(title)) }
        talk.isHidden = !ready; openHost?.view.isHidden = ready || presentation == .preparing
        if presentation == .preparing { preparationSpinner.startAnimating() } else { preparationSpinner.stopAnimating() }
        talk.isEnabled = ready && (phase == .ready || phase == .result || phase == .recording)
        talk.setImage(UIImage(systemName: phase == .recording ? "waveform" : "mic.fill"), for: .normal)
        talk.setTitle(L10n.text(phase == .recording ? "Release to insert" : phase == .finalizing ? "Refining" : "Hold to talk"), for: .normal)
        talk.alpha = talk.isEnabled ? 1 : 0.5
        endButton.isHidden = false
        endButton.setTitle(L10n.text(state?.microphoneActive == true ? "Mic on" : "Mic off"), for: .normal)
        endButton.isEnabled = hasFullAccess && state?.isFresh() == true && (state?.microphoneActive == true || state?.phase == .preparing)
        languageRow.isHidden = presentation == .activationRequired || presentation == .resumePreparation
        sourceButton.isEnabled = phase != .recording && phase != .finalizing && !awaitingStart
        translationButton.isEnabled = sourceButton.isEnabled
        if let state, phase == .result, autoInsertID == state.utteranceID, visible, !state.output.isEmpty,
           let id = state.utteranceID, id != lastInserted {
            autoInsertID = nil
            if anchor?.matches(currentAnchor()) == true { insert(state.output, id: id) }
            else { localError = L10n.text("The text field changed. Tap Insert text when you are ready.") }
        }
        let hasPendingText = state?.utteranceID != nil && state?.utteranceID != lastInserted && !(state?.text.isEmpty ?? true)
        let canInsert = (phase == .result || phase == .failed || phase == .inactive) && hasPendingText
        insertionRow.isHidden = !canInsert
        clearResultButton.isHidden = !canInsert
        insertResult.isHidden = !canInsert
        insertOriginal.isHidden = !canInsert || state?.translation.isEmpty != false
        if canInsert { talk.isHidden = true }
        let useOriginal = state?.configuration.target != nil && state?.translation.isEmpty == true
        insertResult.setTitle(L10n.text(useOriginal ? "Insert original" : "Insert text"), for: .normal)
        status.accessibilityIdentifier = presentation == .preparing ? "keyboard-preparing" : "keyboard-status"
        if let localError { status.text = localError }
        else if !hasFullAccess { status.text = L10n.text("Full Access is required for keyboard dictation.") }
        else if presentation == .preparing { status.text = state?.preparationDetail ?? L10n.text("Preparing dictation…") }
        else if presentation == .resumePreparation { status.text = L10n.text("Open Murmator to finish preparation.") }
        else if let error = state?.error { status.text = error }
        else if ready { status.text = L10n.text(phase == .recording ? "Listening" : phase == .finalizing ? "Refining" : "Ready to dictate") }
        else { status.text = L10n.text("Enable dictation in Murmator") }
        if let state, hasPendingText {
            updatePreview(state.configuration.target == nil ? state.text : state.translation.isEmpty ? state.text : state.translation, state: state)
        } else { preview.text = ""; previewUtterance = nil; previewFinal = false; followsPreview = true }
        hint.text = status.text
        resultCard.backgroundColor = card; resultCard.isHidden = !hasPendingText
        if !hasFullAccess { status.text = L10n.text("Full Access needed") }
        else if presentation == .preparing { status.text = L10n.text("Preparing…") }
        else if !ready { status.text = L10n.text("Activation needed") }
        else { status.text = L10n.text(canInsert ? "Result ready" : phase == .recording ? "Recording" : phase == .finalizing ? "Refining" : "Ready to dictate") }
        if ready && state?.error == nil && localError == nil { hint.text = L10n.text(canInsert ? "Choose what to insert into the current field." : "Hold the microphone while you speak. Release to insert the text.") }
        status.backgroundColor = (ready ? UIColor.systemGreen : accent).withAlphaComponent(0.14)
        status.textColor = ink
        updateReturnKey(); inputView?.invalidateIntrinsicContentSize()
    }
    private func insert(_ text: String, id: UUID) {
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        lastInserted = id; try? KeyboardSessionStore.acknowledge(id)
        anchor = nil
    }
    @objc private func clearCurrentResult() {
        guard let state, let id = state.utteranceID, id != lastInserted,
              state.phase == .result || state.phase == .failed || state.phase == .inactive else { return }
        do {
            #if MURMUR_UI_HOST
            designHandledID = id
            #else
            try KeyboardSessionStore.acknowledge(id)
            #endif
            lastInserted = id; autoInsertID = nil; anchor = nil; localError = nil
        } catch { localError = L10n.text("Could not update the keyboard. Open Murmator and try again.") }
        refresh()
    }
    @objc private func insertOriginalResult() {
        guard let state, let id = state.utteranceID, !state.text.isEmpty else { return }
        insert(state.text, id: id); localError = nil; refresh()
    }
    @objc private func insertCurrentResult() {
        guard let state, let id = state.utteranceID else { return }
        insert(state.output.isEmpty ? state.text : state.output, id: id); localError = nil; refresh()
    }
    @objc private func endSession() { autoInsertID = nil; send(.end) }
    @objc private func backspace() { autoInsertID = nil; anchor = nil; textDocumentProxy.deleteBackward() }
    @objc private func sendReturn() { autoInsertID = nil; anchor = nil; textDocumentProxy.insertText("\n") }
    @objc private func repeatDelete(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { backspace(); deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.backspace() } } }
        else if recognizer.state == .ended || recognizer.state == .cancelled { deleteTimer?.invalidate(); deleteTimer = nil }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === preview { followsPreview = false }
    }
    @objc private func readPreviewBeginning() { followsPreview = false; preview.setContentOffset(.zero, animated: false) }
    @objc private func readPreviewEnd() {
        followsPreview = false
        let length = (preview.text as NSString).length
        if length > 0 { preview.scrollRangeToVisible(NSRange(location: length - 1, length: 1)) }
    }
    private func updatePreview(_ text: String, state: KeyboardSessionState) {
        let newUtterance = previewUtterance != state.utteranceID
        let finished = state.phase == .result && !previewFinal
        guard preview.text != text || newUtterance || finished else { return }
        let offset = preview.contentOffset
        let nearEnd = offset.y + preview.bounds.height >= preview.contentSize.height - 24
        preview.text = text
        preview.layoutIfNeeded()
        if newUtterance || finished {
            preview.setContentOffset(.zero, animated: false)
            followsPreview = newUtterance
        } else if followsPreview && nearEnd && !preview.isDragging && !preview.isDecelerating {
            preview.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        } else { preview.setContentOffset(offset, animated: false) }
        previewUtterance = state.utteranceID; previewFinal = state.phase == .result
    }
    private func updateReturnKey() {
        #if MURMUR_UI_HOST
        let sends = true
        #else
        let sends = textDocumentProxy.returnKeyType == .send
        #endif
        sendButton.setImage(nil, for: .normal)
        sendButton.setTitle(L10n.text(sends ? "Send" : "Return"), for: .normal)
        sendButton.accessibilityLabel = L10n.text(sends ? "Send" : "Return")
    }
    private func languageName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased() }
    private func refreshMenus() {
        let codes = SpeechModelChoice.parakeetLanguages.sorted()
        sourceButton.setTitle("\(configuration.source.uppercased()) ▾", for: .normal)
        sourceButton.accessibilityLabel = L10n.text("Spoken language") + ": " + languageName(configuration.source)
        sourceButton.menu = UIMenu(children: languageActions(codes, preferred: TranslationPaths.offlineRoutes.sources, selected: configuration.source) { [weak self] code in
            guard let self else { return }; self.configuration.source = code
            if self.configuration.target == code { self.configuration.target = nil }; self.changedConfiguration()
        } + [UIMenu(title: L10n.text("Mode"), children: KeyboardRecognitionMode.allCases.map { mode in
            UIAction(title: L10n.text(mode == .fast ? "Fast mode" : "Quality mode"), state: configuration.mode == mode ? .on : .off) { [weak self] _ in self?.configuration.mode = mode; self?.changedConfiguration() }
        })])
        translationButton.setTitle(configuration.target.map { "→ \($0.uppercased()) ▾" } ?? L10n.text("Dictation"), for: .normal)
        translationButton.accessibilityLabel = L10n.text("Translate")
        translationButton.menu = UIMenu(title: L10n.text("Speak & translate"), children: [
            UIAction(title: L10n.text("Dictation"), state: configuration.target == nil ? .on : .off) { [weak self] _ in self?.configuration.target = nil; self?.changedConfiguration() }
        ] + languageActions(LanguagePair.qualityLanguages.sorted().filter { $0 != configuration.source }, preferred: TranslationPaths.offlineRoutes.targets(from: configuration.source), selected: configuration.target) { [weak self] code in self?.configuration.target = code; self?.changedConfiguration() })
    }
    private func languageActions(_ codes: [String], preferred: [String], selected: String?, select: @escaping (String) -> Void) -> [UIMenuElement] {
        let ordered = codes.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
        func actions(_ values: [String]) -> [UIAction] {
            values.map { code in UIAction(title: languageName(code), state: selected == code ? .on : .off) { _ in select(code) } }
        }
        let promoted = ordered.filter { preferred.contains($0) || $0 == selected }
        let other = ordered.filter { !preferred.contains($0) && $0 != selected }
        var menus: [UIMenuElement] = []
        if !promoted.isEmpty { menus.append(UIMenu(title: L10n.text("Your languages"), options: .displayInline, children: actions(promoted))) }
        if !other.isEmpty { menus.append(UIMenu(title: L10n.text("Other languages…"), children: actions(other))) }
        return menus
    }
    private func changedConfiguration() {
        if let saved = KeyboardSessionStore.configuration, saved == configuration { refreshMenus(); refresh(); return }
        if state?.microphoneActive == true { send(.end) }
        do { try KeyboardSessionStore.saveConfiguration(configuration); localError = nil }
        catch { localError = L10n.text("Full Access is required for keyboard dictation.") }
        autoInsertID = nil; refreshMenus(); refresh()
    }
}

private struct KeyboardActivationLink: View {
    let title: LocalizedStringKey
    var body: some View {
        Link(destination: URL(string: "murmur://keyboard")!) {
            Label(title, systemImage: "mic.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(Color.black).background(Color(red: 224/255, green: 122/255, blue: 47/255), in: RoundedRectangle(cornerRadius: 15))
        }.accessibilityIdentifier("keyboard-open-murmur")
    }
}
