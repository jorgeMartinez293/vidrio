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
| `⌘⇧N` | New pane in the current grid, in the same directory |
| `⌘←` `⌘→` `⌘↑` `⌘↓` | Move focus between panes |
| `⌃1…9` | Focus a pane directly |
| `⌘⇧↩` | Zoom the focused pane to the whole window and back. While zoomed, `⌘←` and `⌘→` walk through every pane as one row |
| `⌘W` | Close the focused pane (closes the window when it is the last one) |
| `⌘⇧P` | Command palette: run any action or jump to any pane |
| `⌘⇧O` | Switch workspace |
| `⌥⌘N` | New workspace |
| `⌃⌘←` `⌃⌘→` | Previous or next workspace |
| `⌘⇧U` | Jump to the latest pane with unread activity |
| `⌘F` `⌘G` `⌘⇧G` | Find in the pane's output, next, previous |
| `⌥⌘↑` `⌥⌘↓` | Jump to the previous or next shell prompt |
| `⌘K` | Clear the screen and history |
| `⌘+` `⌘-` `⌘0` | Change the pane's font size, or reset it |
| `⌃⌘F` | Toggle full screen |
| `⌘-click` | Open a URL, or a file path such as `main.swift:42`. Holding `⌘` underlines what can be opened |
| `⌘-drag` a pane | Move it to a new row or column |
| `⌥-drag` a pane | Swap it with another pane |
| `⌘-drag` a window | Merge it into another window |
| `⌘-drag` a pane onto another window | Move it into that window |
| `⌘-drag` a pane outside any window | Open it in a new window |
| `⌘,` | Settings |

Every action's shortcut can be changed in Settings, including two-step chords like `ctrl+b c`.

## Working with agents

- **Notifications.** Programs can notify through OSC 9, 99 or 777. Panes you aren't looking at get a ring, a Dock badge and a desktop notification. The ring's color can be changed in Settings.
- **Pane status.** A dot shows whether the agent in a pane is working, waiting for you, done or stopped with an error. Turn on *Show Claude Code status on panes* in Settings to install the hooks. Any other tool can set the dot by writing `OSC 7771` with `working`, `waiting`, `done`, `error` or `ended`:

  ```sh
  printf '\033]7771;working\007'
  ```

## Workspaces

- **Workspaces.** Named groups of windows, typically one per project. The switcher shows each one's directory, git branch and listening ports.
- **Quick terminal.** An optional global shortcut drops a terminal from the top of the screen, over any app.

## Look and feel

- Translucent window with adjustable blur and opacity (Liquid Glass on macOS 26+, selectable blur materials on older systems).
- Optional solid background color.
- Custom font, size, text and cursor colors.
- Dimmed-text brightness control, so secondary text in CLI tools stays readable.
- Lines and inline images stay square when you resize or run TUIs.
- Settings apply live, with no restart.

## Greeter

New windows can open with an animated sprite and a short system info line. It can show a GIF, a still image, or switch automatically based on battery.

Turn on *Match colors to greeter sprite* in Settings to give each pane a palette, cursor and attention ring that go with its sprite.

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
