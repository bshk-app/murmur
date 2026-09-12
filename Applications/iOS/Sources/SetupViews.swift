import SwiftUI
import MurmurCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = "system"
    @State private var keyboard = false
    @State private var help: StartHelpKind?
    private var p: MurmurPalette { .init(scheme: scheme) }
    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Speech") {
                        VStack(spacing: 0) {
                            NavigationLink { LanguageSetupView(model: model) } label: {
                                HStack { Text("Languages & offline"); Spacer(); Text("\(model.languageLibrary.count)").foregroundStyle(p.muted); chevron }
                                    .padding(15)
                            }.buttonStyle(.plain)
                            Divider().overlay(p.border)
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Text("Spoken language"); Spacer()
                                    LanguageMenu(selection: $model.source, codes: AppLanguages.all.map(\.code), preferred: model.languageLibrary.speech, identifier: "settings-speech-language")
                                }
                                SpeechPriorityPicker(model: model)
                            }.padding(15)
                        }.murmurCard(radius: 16, padding: 0).disabled(model.busy)
                    }
                    section("Tools") {
                        VStack(spacing: 0) {
                            toolRow("Keyboard", symbol: "keyboard") { model.showKeyboardSetup = true }
                            Divider().overlay(p.border)
                            toolRow("Audio imports", symbol: "waveform") { model.requestUtilityRoute("audio-import") }
                            #if !MURMUR_UI_HOST
                            Divider().overlay(p.border)
                            toolRow("Canary experiment", symbol: "waveform.badge.magnifyingglass") { model.requestUtilityRoute("canary") }
                                .accessibilityIdentifier("open-canary")
                            #endif
                            if #available(iOS 18.4, *) {
                                Divider().overlay(p.border)
                                toolRow("Default translation app", symbol: "character.bubble") {
                                    UIApplication.shared.open(URL(string:UIApplication.openDefaultApplicationsSettingsURLString)!)
                                }.accessibilityIdentifier("open-default-translation-settings")
                            }
                        }.murmurCard(radius: 16, padding: 0)
                    }
                    section("Device") {
                        toolRow("Storage", symbol: "internaldrive") { model.requestUtilityRoute("storage") }.murmurCard(radius: 16, padding: 0).accessibilityIdentifier("open-storage")
                        toolRow("Memory", symbol: "memorychip") { model.showMemory = true }.murmurCard(radius: 16, padding: 0)
                    }
                    section("Ways to start") {
                        NavigationLink { PageTranslationHelpView() } label: {
                            Label(PageL10n.text("Translate Safari pages"), systemImage: "safari").padding(15).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).murmurCard(radius: 16, padding: 0).accessibilityIdentifier("page-translation-help")
                        VStack(spacing: 0) {
                            helpRow("Action Button") { help = .action }
                            Divider().overlay(p.border)
                            helpRow("Murmator keyboard") { keyboard = true }
                            Divider().overlay(p.border)
                            helpRow("Widget & Live Activity") { help = .widget }
                        }.murmurCard(radius: 16, padding: 0)
                    }
                    section("Appearance") {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("Theme")
                            Picker("Theme", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
                        }.murmurCard(radius: 16, padding: 15)
                    }
                    NavigationLink { AboutView() } label: {
                        HStack { Text("About Murmator"); Spacer(); chevron }.padding(15).contentShape(Rectangle())
                    }.buttonStyle(.plain).murmurCard(radius: 16, padding: 0)
                        .accessibilityIdentifier("open-about")
                    Button("Replay setup tour") { dismiss(); UserDefaults.standard.set(false, forKey: "onboardingComplete") }
                        .frame(maxWidth: .infinity).foregroundStyle(MurmurPalette.accent).disabled(model.busy)
                    HStack(spacing: 5) {
                        Text("Version")
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        Text("·")
                        Text("Build")
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                    }.font(.caption).foregroundStyle(p.muted).frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("settings-version")
                }.font(.system(size: 16)).padding(.horizontal, 20).padding(.bottom, 20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.background(p.background).foregroundStyle(p.ink).navigationTitle("Settings").navigationBarTitleDisplayMode(.large).toolbar(.visible, for: .navigationBar)
                .onChange(of: model.source) { model.recommendModel(); Task { await model.updateSettings() } }
                .onChange(of: model.mode) { Task { await model.updateSettings() } }
                .alert("Murmator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("OK", role: .cancel) { model.error = nil }
                } message: { Text(model.error ?? "") }
                .sheet(isPresented: $keyboard) { KeyboardHelpView() }
                .sheet(item: $help) { StartHelpView(kind: $0) }
        }.tint(MurmurPalette.accent)
    }
    private func toolRow(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(p.accentText).frame(width: 22)
                Text(title).font(.body)
                Spacer(minLength: 0); chevron
            }.frame(minHeight: 60).padding(.horizontal, 15).padding(.vertical, 9)
        }.buttonStyle(.plain)
    }
    private var chevron: some View { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(p.muted) }
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11.5, weight: .medium)).tracking(0.7).textCase(.uppercase).foregroundStyle(p.muted)
            content()
        }
    }
    private func helpRow(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(title); Spacer(); Text("Help").foregroundStyle(p.muted); chevron }.padding(15) }.buttonStyle(.plain)
    }
}

enum StartHelpKind: String, Identifiable { case action, widget; var id: String { rawValue } }
struct StartHelpView: View {
    let kind: StartHelpKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(LocalizedStringKey(kind == .action ? "Action Button" : "Widget & Live Activity")).font(.system(size: 17, weight: .semibold))
                Spacer(); Button("Done") { dismiss() }
            }
            Image(systemName: kind == .action ? "button.programmable" : "lock.rectangle").font(.system(size: 32)).foregroundStyle(MurmurPalette.accent)
            Text(LocalizedStringKey(kind == .action ? "Assign “Record a Murmator note” in Action Button or Shortcuts settings." : "Add the Murmator widget to your Lock Screen. It opens the app for recording."))
                .font(.system(size: 16)).lineSpacing(5)
            Spacer(minLength: 0)
        }.padding(20).padding(.top, 12).foregroundStyle(p.ink).presentationBackground(p.background)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible).tint(MurmurPalette.accent)
    }
}

struct KeyboardHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:22) {
                Image(systemName:"keyboard").font(.system(size:42)).foregroundStyle(MurmurPalette.accent)
                Text("Your words, in any app.").font(.title.bold())
                Text("1. Add Murmator in Settings → General → Keyboard.\n\n2. Enable Full Access for Murmator.\n\n3. Select Murmator with the globe key, enable the microphone, then hold to talk.").foregroundStyle(.secondary)
                Spacer()
            }.padding(24).navigationTitle("Murmator keyboard").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {dismiss()}}}
        }
    }
}
