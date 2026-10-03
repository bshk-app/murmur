# Handoff — Murmator Photo Translate Prototype

Source: Claude Design project `71b76ff3-1995-4810-8583-36908c45101d` ("MurMur Voice to Text дизайн"),
file `Murmator Photo Translate Prototype.dc.html` (etag `1789737630482177`, 35,141 bytes).
Exported source: `Murmator Photo Translate Prototype.dc.html` next to this file.

Flow: photo → partial result → failed block → fix recognized text → retranslate one block → full result.
Scenario: Finnish sign → Russian. Block 2 is misrecognized: `AVOlNNA 9–21` (a pole next to the text
was read as a lowercase `l`). The correct text is `AVOINNA 9–21` → `Открыто 9–21`.

Referenced resources, exported next to this file: `support.js` (DC runtime), `mascot.png`, `mascot-mono.png`.

## Props

| Prop | Type | Default | Effect |
|---|---|---|---|
| `theme` | `'light' \| 'dark'` | `light` | Sets `data-theme` on the phone frame |
| `withError` | boolean | `true` | `true`: shoot → `res` (block 2 fails). `false`: shoot → `done` |
| `numbers` | boolean | `false` | Shows 1/2/3 index badges on photo plaques |

Preview canvas: 460×1010. Phone frame: 393×852, radius 44, status bar 54 pt.

## States

| Stage | Label (below the frame) | What is on screen |
|---|---|---|
| `cam` | Шаг 1 · камера готова | Language pill `Финский → Русский ▼`. Hint card with mono mascot: «Наведите на текст и снимите» / «Перевод появится поверх надписей. Можно взять готовый снимок из галереи.». Bottom row: `Галерея` (60×60) · shutter (78×78 white) · `Авто` (60×60) |
| `proc` | Шаг 2 · распознавание и перевод | 3 shimmer skeleton plaques over the sign. Progress card with 3 pulsing dots: «Читаем текст на фото» / «Готовые блоки покажем сразу, как только переведутся» + `Отмена` |
| `res` | Шаг 3 · частичный результат: 2 из 3 | Top bar: `✕` · language pill · `Оригинал` toggle. Plaques 1 and 3 translated. Block 2 is a dashed red plaque: `!` + `AVOlNNA 9–21` + «НЕ ПЕРЕВЕДЕНО». `↻` and `⌗ Другое фото` above the sheet. Sheet «Полный текст», subtitle «2 переведено · 1 с ошибкой», `Поделиться`, rows 1–3. Row 2 is the error row: red left border, tint, «Не удалось перевести», source text, «Разобрать ›» |
| `err` | Шаг 4 · разбор неудачного блока | Photo dimmed. Failed plaque gets an orange 2.5 pt focus ring. Sheet: «Этот блок не удалось перевести» + reason. Card «РАСПОЗНАНО НА ФОТО» with the bad `l` highlighted (err tint + 2 pt underline). Buttons: `Исправить текст` (primary), `Повторить перевод блока` (secondary), `Пропустить` (tertiary) |
| `edit` | Шаг 5 · исправление распознанного текста | Photo dimmed. Nav: `Отменить` · «Исправить текст» · `Готово`. Field (2 pt accent border, caret) shows `editText`. Hint text. Suggestion chip «Убрать лишнюю «l»» → `AVOINNA`. Primary `Перевести этот блок`. Keyboard placeholder (10/9/6 keys) |
| `fix` | Шаг 6 · повторный перевод одного блока | Plaques 1 and 3 stay. Block 2 is an orange-ringed shimmer plaque. Progress card: «Переводим исправленный блок» / «Остальные переводы остаются на месте». No cancel |
| `done` | Шаг 7 · полный результат | All 3 plaques translated (`ОТКРЫТО 9–21`). Sheet subtitle «3 блока · финский → русский». Toast «✓ Блок переведён» for 2.4 s after a fix |

Other local state:
- `orig` (top bar, every stage after `proc`): `Оригинал` hides all plaques, so the photo is visible. The button changes to `Перевод` (white bg, `#241F1C` text).
- `charFixed`: set by the suggestion chip. Changes `editText` to `AVOINNA 9–21`, sets the hint to «Лишняя «l» убрана. Перевод пересчитается только для этого блока.», and hides the chip. Default hint: «Проверьте распознанный текст. Правка касается только этого блока.».
- `toast`: shown only after `fix` → `done`.

## Interactions

| From | Control | Result |
|---|---|---|
| `cam` | Shutter | → `proc`; after 1700 ms → `res` (withError) or `done` |
| `proc` | `Отмена` | Reset to `cam` |
| `res` | Dashed plaque, or sheet row «Разобрать ›» | → `err` |
| `res`/`err`/`edit`/`fix`/`done` | `✕` | Reset to `cam` |
| `res`/`done` | `⌗ Другое фото` | Reset to `cam` |
| `res`/`err`/`edit`/`fix`/`done` | `Оригинал` / `Перевод` | Toggle `orig` |
| `err` | `Исправить текст` | → `edit` |
| `err` | `Повторить перевод блока` | → `fix`; after 1400 ms → `done` + toast |
| `err` | `Пропустить` | → `res` |
| `edit` | Suggestion chip | `charFixed = true` |
| `edit` | `Готово` or `Перевести этот блок` | → `fix`; after 1300 ms → `done` + toast |
| `edit` | `Отменить` | → `res` (`charFixed` is kept) |
| `done` | (auto) | Toast hides after 2400 ms |
| page | `Начать заново` (outside frame) | Reset everything |

Static (no handler in the prototype): language pill, `Галерея`, `Авто`, `↻`, `Поделиться`.

Implementation note: `reset` does not clear pending timers. If you tap `Отмена` during `proc`, the 1700 ms timer still moves the screen to `res`. The real app must cancel the in-flight job on cancel/close.

Dim scrim `rgba(8,6,5,.58)` is on only in `err` and `edit`.

## Layout (frame coordinates, pt)

- Sign on the photo: inset 34 left/right, top 150, height 286, radius 6.
- Plaque 1: inset 34, top 224, padding 10/12, radius 9, full width, centered text.
- Plaque 2: centered, top 283 (bad) / 284 (good, fixing 190×34), radius 8–9.
- Plaque 3: centered, top 330, padding 6/10, radius 8.
- Plaque shadow `0 3px 14px rgba(0,0,0,.3)`. Focused bad plaque: `0 0 0 2.5px var(--acc), 0 8px 26px rgba(0,0,0,.4)`.
- Floating controls: 44 pt high, radius 22, `rgba(18,16,14,.55)` + `backdrop-filter: blur(14px)`.
- Camera/progress cards: margin 0 20, padding 15/16, radius 18, blur 16.
- Sheets: radius 16 16 0 0, grabber 38×5, side padding 18. List sheet shadow `0 -10px 34px rgba(0,0,0,.26)`; error sheet `.34`.
- Buttons: primary/secondary 50 high, radius 14. Tertiary 44 high. Chip 46 high, radius 13. `Поделиться` 36 high, radius 18.
- Home indicator: 140×5, radius 3.

## Typography

Font stack: `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif`. Index numbers use `ui-monospace, Menlo, monospace`.
Format: weight size/line-height (tracking).

| Role | Spec |
|---|---|
| Plaque 1 (headline) | 700 26/1.1 (−0.015em), centered |
| Plaque 2 (good) | 600 17/1.1 |
| Plaque 2 (bad) text | 500 17/1.2 |
| «НЕ ПЕРЕВЕДЕНО» tag | 600 10/1.2, uppercase, +0.05em, `--err` |
| Plaque 3 | 500 14/1.2 |
| Plaque index badge | 600 10–11/1 mono, 18–20 circle, `--fill2` / `--plaqueSub` |
| Language pill | 600 15/1 |
| Camera / progress title | 600 16/1.3, white |
| Camera hint body | 400 14/1.45, white 76% |
| Progress subtitle | 400 13.5/1.4, white 72% |
| Sheet title «Полный текст» | 600 17/1.2 |
| Sheet subtitle | 400 13/1.3, `--ink3` |
| List translation | 400 17/1.4, `--ink` |
| List original | 400 13/1.35, `--ink3` |
| List index | 600 12/1.5 mono, `--ink3`, 20 wide |
| Error row label | 600 13/1.3, `--err` |
| Error row source | 400 15/1.35, `--ink2` |
| «Разобрать ›» | 600 14/1, `--accT` |
| Error sheet title | 700 21/1.25 (−0.015em) |
| Error sheet body | 400 15/1.45, `--ink2` |
| Card caption «РАСПОЗНАНО НА ФОТО» | 600 10.5/1.4, uppercase, +0.06em, `--ink3` |
| Recognized text | 400 17/1.4 |
| Primary / secondary button | 600 16/1 |
| Tertiary button | 500 15/1, `--ink2` |
| Edit nav: cancel / title / done | 400 17/1.2 `--accT` · 600 16/1.2 · 600 17/1.2 `--accT` |
| Edit field | 400 19/1.4, caret 2×22 `--acc` |
| Edit hint | 400 13.5/1.45, `--ink3` |
| Suggestion chip | 500 15/1, value 600 `--accT` |
| Toast | 600 14/1.2, white |
| `Оригинал` toggle / `Другое фото` | 500 14/1 |
| `Галерея` / `Авто` caption | 500 10/1 (icon 400 19) |

## Colors

Theme tokens (on the phone frame via `data-theme`):

| Token | Light | Dark | Used for |
|---|---|---|---|
| `--sheet` | `#FFFDF9` | `#1E1916` | Sheet bg; `!` glyph on err badge |
| `--card` | `#FFFDF9` | `rgba(255,255,255,.07)` | Cards, secondary button, keyboard keys |
| `--ink` | `#2A2520` | `rgba(255,255,255,.95)` | Primary text |
| `--ink2` | `rgba(74,62,52,.74)` | `rgba(255,255,255,.68)` | Secondary text |
| `--ink3` | `rgba(74,62,52,.52)` | `rgba(255,255,255,.46)` | Tertiary text, captions, indices |
| `--line` | `rgba(60,40,20,.11)` | `rgba(255,255,255,.12)` | Dividers, borders |
| `--fill` | `rgba(60,40,20,.07)` | `rgba(255,255,255,.10)` | Suggestion chip bg |
| `--fill2` | `rgba(60,40,20,.12)` | `rgba(255,255,255,.16)` | Grabber, home indicator, badges, modifier keys |
| `--acc` | `#E07A2F` | `#E07A2F` | Primary buttons, focus ring, caret, field border |
| `--accT` | `#C9722C` | `#F0A469` | Accent text (links, nav buttons) |
| `--err` | `#A52A17` | `#F0A194` | Error text, dashed border, error badges |
| `--errTint` | `rgba(165,42,23,.11)` | `rgba(240,161,148,.13)` | Error row bg, highlight on bad char |
| `--plaque` | `rgba(252,250,246,.955)` | `rgba(26,22,19,.95)` | Translation plaques over the photo |
| `--plaqueInk` | `#251F1A` | `rgba(255,255,255,.95)` | Plaque text |
| `--plaqueSub` | `rgba(74,62,52,.6)` | `rgba(255,255,255,.6)` | Plaque index badges |
| `--sys` | `#e7e3dd` | `#2a2521` | Keyboard background |

Defined but not used in this file: `--accTint`, `--plaqueWeak`, `--plaqueWeakInk`.

Fixed colors (not themed):
- Camera chrome: `rgba(18,16,14,.55)` buttons, `.5` for Галерея/Авто (border `rgba(255,255,255,.28)`), `.62` hint card, `.66` progress card, `.78` toast.
- Shutter: `#fff` with ring `0 0 0 4px rgba(255,255,255,.34)`.
- Success badge: `#8DCCA1` bg, `#12281B` check.
- Dim scrim: `rgba(8,6,5,.58)`.
- Home indicator over the camera: `rgba(255,255,255,.55)`.
- Shimmer: `rgba(160,150,140,.5)`. Fixing shimmer: `rgba(224,122,47,.45)`.
- Mock photo: `#37423F`, `#2E3836`, sign `#D8D0BF` + gradient overlay, `#46514D`.
- Page (outside the frame): `#e9e4dc`, text `#2a2520` / `rgba(74,62,52,.6)`.

## Motion

| Name | Spec | Used on |
|---|---|---|
| `mshimmer` | translateX −70% → 280%, 1.5 s linear infinite, delays 0 / .25 / .5 s | Skeleton plaques in `proc` |
| `mshimmer` (fix) | 1.2 s linear infinite, orange | Block 2 in `fix` |
| `mpulse` | opacity 1 → .4 → 1, 1.1 s ease-in-out infinite, delays 0 / .2 / .4 s | 3 dots in progress cards |
| `mrise` | opacity 0→1, translateY 10→0, .22 s ease-out | Toast enter |

Prototype timings: processing 1700 ms, block retry 1400 ms, retranslate after edit 1300 ms, toast 2400 ms.
