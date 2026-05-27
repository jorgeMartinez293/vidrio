# Terminal Settings Window — Design

**Date:** 2026-05-28
**Status:** Approved (pending spec review)

## Goal

Add a native macOS Settings window to LiquidTerminal, reachable from the app menu
(first menu, next to the Apple menu) via "Ajustes…" with the `⌘,` shortcut. The
window lets the user configure how new terminal windows open: size, background
color + opacity, blur, font, text/cursor color, and corner radius. A
"Restaurar valores por defecto" button resets everything to the current
hardcoded behavior.

The existing transparency/blur is preserved and expanded, not replaced.

## Scope

- Settings apply to **new windows only**. Already-open windows are not mutated.
  This keeps the implementation free of live-propagation plumbing.
- No shell-selection setting (explicitly out of scope).
- The GUI is not unit-tested; only the pure settings model/store logic is.

## Architecture

Four new units, two modified:

### New

1. **`TerminalSettings`** — a `Codable` struct holding all configurable fields,
   with `static let defaults` equal to today's hardcoded behavior. Range
   clamping lives here (applied on decode and on mutation).

2. **`SettingsStore`** — a `@MainActor` singleton persisting `TerminalSettings`
   to `UserDefaults` (single JSON-encoded key). Exposes `current`, `save()`,
   and `resetToDefaults()`. Source of truth read at window creation.

3. **`SettingsView`** — a SwiftUI `Form` with `.formStyle(.grouped)` (macOS 13
   Ventura "System Settings" look — the most native option, least code). Binds
   to a `@StateObject` view model wrapping `SettingsStore`. Includes a small
   live preview swatch so color/opacity/blur choices are visible before opening
   a new window.

4. **`SettingsWindowController`** — owns a single `NSWindow` hosting
   `SettingsView` via `NSHostingController`. Single-instance: re-opening brings
   the existing window forward. Standard titled/closable window (not the
   transparent terminal window).

### Modified

5. **`AppDelegate`**
   - `setupMenu()`: add "Ajustes…" item to the app menu with `keyEquivalent: ","`,
     action opening `SettingsWindowController`.
   - `createNewWindow()`: read `SettingsStore.current`; compute pixel window size
     from cols×rows + font cell metrics + insets; pass the settings into
     `TerminalViewController`.

6. **`TerminalViewController`** — accept a `TerminalSettings` (injected before
   `viewDidLoad`, default `.defaults`). `setupTerminal()` uses it to configure:
   - `NSVisualEffectView.material` (or hide the view when blur = "Ninguno"),
   - the background color overlay layer (see semantics below),
   - terminal `font`, `nativeForegroundColor`, `caretColor`,
   - `layer.cornerRadius` on terminal + visual effect views.

## Fields & defaults (defaults == current behavior)

| Field | Type | Default | UI control |
|---|---|---|---|
| `cols` | Int | value reproducing ~800×600 with SF Mono 14 (computed from measured cell metrics, see below) | stepper |
| `rows` | Int | same | stepper |
| `blurMaterial` | enum | `.hudWindow` | popup incl. "Ninguno" |
| `backgroundColorEnabled` | Bool | `false` | toggle ("sin color" when off) |
| `backgroundColor` | RGBA | black (inactive) | `ColorPicker` |
| `opacity` | Double | `1.0` | slider 0–1 |
| `fontName` | String | `"SF Mono"` | popup of monospace fonts |
| `fontSize` | Double | `14` | stepper |
| `textColor` | RGBA | white | `ColorPicker` |
| `cursorColor` | RGBA | white | `ColorPicker` |
| `cornerRadius` | Double | `16` | slider 0–40 |

Colors persist as RGBA components (Doubles) inside the JSON, not as archived
`NSColor`, to keep `Codable` simple and platform-stable.

### `blurMaterial` enum

Cases map to `NSVisualEffectView.Material`: `hudWindow` (default),
`popover`, `sidebar`, `fullScreenUI`, `underWindowBackground`, `menu`, plus a
synthetic `none` case. `none` hides the `NSVisualEffectView` entirely. The popup
labels are user-facing names ("HUD", "Popover", "Barra lateral", "Pantalla
completa", "Bajo ventana", "Menú", "Ninguno").

## Background color semantics

A background-color overlay layer sits **between** the blur (`NSVisualEffectView`,
behind) and the terminal text (front). The terminal's `nativeBackgroundColor`
stays `.clear` so lower layers show through.

- `backgroundColorEnabled = false` → no overlay → pure blur. **Exactly today's
  behavior.**
- `backgroundColorEnabled = true` → overlay = `backgroundColor` with
  `alpha = opacity`.
  - `opacity = 1.0` → solid color, blur hidden.
  - `opacity = 0.0` → blur fully visible.
- `blurMaterial = none` + color disabled → fully transparent window (no blur, no
  color).

The overlay is a dedicated layer/view added in `setupTerminal()` between the
visual effect view and the terminal view, with matching corner radius.

## Window size from cols×rows

At `createNewWindow()`:

```
cellW, cellH = metrics for (fontName, fontSize)   // measured once
contentW = cols * cellW + horizontalInsets         // insets: leading 10 + trailing 10
contentH = rows * cellH + verticalInsets           // insets: top 50 + bottom 10
```

Cell metrics: prefer SwiftTerm's reported cell dimensions if exposed by the
vendored `TerminalView`; otherwise measure the font's advancement (`maximumAdvancement`/
glyph width) and line height. The implementation plan must confirm which API the
vendored SwiftTerm provides before choosing.

Default `cols`/`rows` are computed so the default window reproduces the current
800×600 size with SF Mono 14 (approx. 90×30; exact values derived from measured
metrics during implementation, not hardcoded guesses).

## Data flow

```
UserDefaults  <->  SettingsStore  ->  SettingsView (reads + writes via VM)
                          \-> AppDelegate.createNewWindow (reads at creation)
                               -> TerminalViewController (applies)
```

Writes happen immediately on each control change (System-Settings-style:
no Save button). `resetToDefaults()` writes `.defaults` and the bound view
refreshes.

## Error handling

- Clamp on decode and mutation: `cols` 20–400, `rows` 5–200, `opacity` 0–1,
  `fontSize` 8–48, `cornerRadius` 0–40.
- Missing/invalid `fontName` → fall back to `monospacedSystemFont`, mirroring
  current code.
- Corrupt/absent `UserDefaults` payload → `TerminalSettings.defaults`.

## Testing

Add a test target (`LiquidTerminalTests`) covering pure logic only:

- `TerminalSettings` encode→decode round-trip preserves values.
- Clamping enforces every range bound.
- Corrupt JSON decodes to `.defaults`.
- `SettingsStore.resetToDefaults()` yields `.defaults`.
- Window-size computation: given cols/rows + known cell metrics, returns expected
  content size (metrics injected, not measured, for determinism).

GUI (`SettingsView`, window controller, menu) is verified manually.

## Out of scope / YAGNI

- Live application to already-open windows.
- Per-window (vs global) settings.
- Shell selection, theme presets/import-export, keybindings.
- Numeric blur radius via private API (rejected: fragile across macOS versions).
