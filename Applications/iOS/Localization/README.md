# App localization

The initial interface languages are English, Russian, German, Spanish, French and Finnish. iOS chooses the language from the user's preferred languages and per-app language setting, independently of the dictation language. English is the fallback. The speech/translation picker uses localized system language names and the engine language catalog; having an interface translation does not change model availability.

`translations.tsv` is the editable source. Every row must have every language and matching format placeholders. Generate resources with:

```sh
uv run Applications/iOS/Localization/generate.py
```

Generated `Localizable.strings` and `InfoPlist.strings` are embedded in the app, keyboard and widget. SwiftUI literals use normal localization. Dynamic UI keys use `LocalizedStringKey`; model state and UIKit use `L10n`. User transcripts and model/file identifiers are never treated as localization keys. Upstream diagnostic text may retain the library's language.

The device UI test checks Russian onboarding text, stable mascot bounds across pages and after preparation, the enabled Continue button without preparation, and completion of all five optional steps. No microphone permission is requested by preparation.
