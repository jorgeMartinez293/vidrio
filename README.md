# Vidrio

A native macOS terminal that tiles your sessions automatically. Lightweight, minimalist, and aesthetic.

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

### Rearranging

- **Rearrange panes:** hold `⌘` and drag a pane. It lifts out of the grid, with a live preview of the landing slot. Over the left or right side of a column (at any height) it opens a new column there; anywhere else in a column it goes in as a row, above the pane under the pointer if you're over its upper half and below it if over its lower half.
- **Swap panes:** hold `⌥` and drag a pane to trade places with the one you drop it on. You can switch between `⌘` and `⌥` mid-drag, and pick other keys for both in Settings.
- **Merge windows:** hold `⌘` and drag a whole window onto another one. The target's panes spring aside to make room, and every session, live shells included, moves into the target window.
- **Move panes between windows:** hold `⌘` and drag a pane out of its window. The other panes close the gap. Drop it on another window and it lands in a new row or column there, picked the same way as when rearranging; drop it anywhere else and it opens in a window of its own. Its live shell comes along either way.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New window |
| `⌘⇧N` | New pane in the current grid |
| `⌘←` `⌘→` `⌘↑` `⌘↓` | Move focus between panes |
| `⌘W` | Close the focused pane (closes the window when it is the last one) |
| `⌘-drag` a pane | Move it to a new row or column |
| `⌥-drag` a pane | Swap it with another pane |
| `⌘-drag` a window | Merge it into another window |
| `⌘-drag` a pane onto another window | Move it into that window |
| `⌘-drag` a pane outside any window | Open it in a new window |
| `⌘,` | Settings |

## Look and feel

- Translucent window with adjustable blur and opacity (Liquid Glass on macOS 26+, selectable blur materials on older systems).
- Optional solid background color.
- Custom font, size, text and cursor colors.
- Dimmed-text brightness control, so secondary text in CLI tools stays readable.
- Lines and inline images stay square when you resize or run TUIs.
- Settings apply live, with no restart.

## Greeter

New windows can open with an animated sprite and a short system info line. It can show a GIF, a still image, or switch automatically based on battery.

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
