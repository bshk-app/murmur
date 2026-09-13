import SwiftUI
import MurmurCore

struct KeyboardDictationView: View {
    @Bindable var controller: KeyboardDictationController
    let onEnable: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var options = false
    @State private var help = false
    private var p: MurmurPalette { .init(scheme: scheme) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Keyboard dictation").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.frame(minHeight: 44).foregroundStyle(p.accentText) }.padding(.horizontal, 20).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 11) {
                            Circle().fill(controller.modelsReady ? Color(hex: 0x2e7a4a) : MurmurPalette.accent).frame(width: 10, height: 10).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(LocalizedStringKey(controller.summaryTitle)).font(.headline)
                                    .accessibilityIdentifier(controller.state.phase == .preparing ? "keyboard-preparing" : controller.modelsReady ? "keyboard-ready" : "keyboard-inactive")
                                if controller.state.phase == .preparing { Text(controller.detail).font(.subheadline).foregroundStyle(p.secondary) }
                            }
                        }
                        if controller.state.phase == .preparing {
                            ProgressTrack()
                            DesignButton(title: "Prepare dictation", action: {}).disabled(true)
                            DesignButton(title: "Cancel", kind: .link) { Task { await controller.end() } }
                        } else if controller.isActive {
                            DesignButton(title: "End dictation", kind: .secondary) { Task { await controller.stopAndEnd() } }.accessibilityIdentifier("keyboard-disable")
                        } else {
                            DesignButton(title: "Prepare dictation") { Task { await onEnable() } }.accessibilityIdentifier("keyboard-enable")
                            DesignButton(title: "Keyboard setup instructions", kind: .link) { help = true }
                        }
                        if let method = controller.state.translationMethod {
                            Label(method == .direct ? "Direct translation" : "Translation through text",
                                  systemImage: method == .direct ? "waveform.and.person.filled" : "text.bubble")
                                .font(.footnote).foregroundStyle(p.secondary)
                                .accessibilityIdentifier("keyboard-translation-method")
                        }
                    }.murmurCard(radius: 18, padding: 16)
                    VStack(spacing: 0) {
                        statusRow("Full Access", value: controller.fullAccessConfirmed ? "Confirmed" : "Check in keyboard", good: controller.fullAccessConfirmed)
                        Divider().overlay(p.border)
                        statusRow("Microphone", value: controller.microphoneAllowed ? "Allowed" : "Not allowed", good: controller.microphoneAllowed)
                        Divider().overlay(p.border)
                        statusRow("Session", value: controller.modelsReady ? "Ready to dictate" : controller.state.phase == .preparing ? "Preparing…" : "Inactive", good: controller.modelsReady)
                    }.murmurCard(radius: 16, padding: 0)
                    DisclosureGroup("Language and mode", isExpanded: $options) {
                        VStack(alignment: .leading, spacing: 14) {
                            LanguageMenu(selection: $controller.configuration.source, codes: controller.languages.map(\.code), preferred: TranslationPaths.offlineRoutes.sources, identifier: "keyboard-setup-source")
                            Toggle("Translate", isOn: Binding(get: { controller.configuration.target != nil }, set: { enabled in controller.configuration.target = enabled ? (controller.configuration.source == "en" ? "ru" : "en") : nil }))
                            if controller.configuration.target != nil {
                                LanguageMenu(selection: Binding(get: { controller.configuration.target ?? "en" }, set: { controller.configuration.target = $0 }), codes: controller.translationLanguages.filter { $0.code != controller.configuration.source }.map(\.code), preferred: TranslationPaths.offlineRoutes.targets(from: controller.configuration.source), identifier: "keyboard-setup-target")
                            }
                            Picker("Mode", selection: $controller.configuration.mode) {
                                Text("Fast").tag(KeyboardRecognitionMode.fast); Text("Accurate").tag(KeyboardRecognitionMode.accurate)
                            }.pickerStyle(.segmented)
                        }.padding(.top, 12).disabled(controller.isActive)
                    }.murmurCard(radius: 16, padding: 15)
                    if let error = controller.state.error { Text(error).font(.footnote).foregroundStyle(Color(hex: 0xc0341f)).accessibilityIdentifier("keyboard-session-error") }
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.foregroundStyle(p.ink).presentationBackground(p.sheet).presentationCornerRadius(26).presentationDetents([.large]).tint(p.accentText)
            .onChange(of: controller.configuration.source) { _, source in if controller.configuration.target == source { controller.configuration.target = source == "en" ? "ru" : "en" } }
            .sheet(isPresented: $help) { KeyboardHelpView() }
    }
    private func statusRow(_ title: LocalizedStringKey, value: LocalizedStringKey, good: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            StatusTag(title: value, tone: good ? .success : .neutral)
        }.padding(15)
    }
}
