# Vidrio

A native macOS terminal that tiles your sessions automatically. Lightweight, minimalist, and aesthetic.

<!-- SCREENSHOT: hero shot. A multi-pane grid over a nice wallpaper, translucent blur visible. -->
<p align="center">
  <img src="docs/screenshots/hero.png" alt="Tiling Terminal hero screenshot" width="900">
</p>

## Highlights

- **Tiling window management.** Panes arrange themselves into a grid that fills the window. No manual resizing, no dragging dividers around.
- **Native.** Written in Swift with AppKit. No Electron, no web view, no bundled runtime.
- **Lightweight.** Small binary, low memory footprint, instant startup.
- **Minimalist.** No tab bars, no toolbars, no clutter. Just your shells and the glass behind them.
- **Beautiful.** Translucent blurred backgrounds, rounded chrome, smooth spring animations, and a customizable animated greeter.

## Tiling

Every window is a grid of live terminal sessions.

- New panes open **without moving the existing ones**.
- The grid stays as square as the pane count allows, and each column splits its height evenly between its panes.
- The **focused pane grows** so it always reads as the main one.
- Moving between panes is a single shortcut away.

<!-- SCREENSHOT: a window with 3-4 panes tiled, one of them focused and larger. -->
<p align="center">
  <img src="docs/screenshots/tiling.png" alt="Tiled panes with a focused pane enlarged" width="800">
</p>

### Rearranging

- **Swap panes:** hold `⌘` and drag a pane by its top strip. It lifts out of the grid and trades places with the one you drop it on, with a live preview of the landing slot.
- **Merge windows:** hold `⌘` and drag a whole window onto another one. The target's panes spring aside to make room, and every session, live shells included, moves into the target window.

<!-- SCREENSHOT or GIF: dragging a pane to swap it / merging two windows. -->
<p align="center">
  <img src="docs/screenshots/rearrange.gif" alt="Dragging panes and merging windows" width="800">
</p>

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New window |
| `⌘⇧N` | New pane in the current grid |
| `⌘←` `⌘→` `⌘↑` `⌘↓` | Move focus between panes |
| `⌘W` | Close the focused pane (closes the window when it is the last one) |
| `⌘-drag` a pane | Swap it with another pane |
| `⌘-drag` a window | Merge it into another window |
| `⌘,` | Settings |

## Look and feel

- Translucent window with adjustable blur material and opacity.
- Optional solid background color.
- Custom font, size, text and cursor colors.
- Dimmed-text brightness control, so secondary text in CLI tools stays readable.
- Lines and inline images stay square when you resize or run TUIs.
- Settings apply live, with no restart.

<!-- SCREENSHOT: the settings window. -->
<p align="center">
  <img src="docs/screenshots/settings.png" alt="Settings window" width="700">
</p>

## Greeter

New windows can open with an animated sprite and a short system info line. It can show a GIF, a still image, or switch automatically based on battery.

<!-- SCREENSHOT: a fresh window showing the greeter sprite and info line. -->
<p align="center">
  <img src="docs/screenshots/greeter.png" alt="Greeter with animated sprite" width="700">
</p>

## Requirements

- macOS 13 or later
- Apple Silicon or Intel (universal build)

## Installation

Download the latest release, drag the app to `/Applications`, and open it. The app updates itself through Sparkle.

### Build from source

You need the Swift toolchain (Xcode or the Command Line Tools).

```sh
git clone --recurse-submodules git@github.com:jorgeMartinez293/vidrio.git
cd vidrio

make run      # build and launch
make test     # run the test suite
make bundle   # build a universal, signed .app bundle
make dmg      # package a .dmg
```

If you already cloned without submodules, run `git submodule update --init`.

## Built with

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation (via a fork in `Vendor/SwiftTerm`)
- [Sparkle](https://sparkle-project.org) for auto-updates

## License

MIT. See [LICENSE](LICENSE).
