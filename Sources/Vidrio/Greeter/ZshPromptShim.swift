import Foundation

/// Injects vidrio's prompt-color tinting into zsh without touching the user's `.zshrc`.
/// A plain inherited `PROMPT` env var isn't enough: a shell framework (oh-my-zsh, a theme,
/// starship, ...) sourced from `.zshrc` typically assigns `PROMPT` itself, clobbering
/// whatever the shell inherited. sereno's old approach worked around this by appending its
/// prompt function at the very end of `.zshrc`, guaranteeing it ran last — but that meant
/// editing the user's dotfile.
///
/// This does the same "run last" trick without touching it, using zsh's own `ZDOTDIR`
/// mechanism: point zsh at a small shim rc pair that sources the user's real dotfiles, then
/// sets `PROMPT` from `$VIDRIO_PROMPT` as the final step.
enum ZshPromptShim {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vidrio/zdotdir")

    /// The ZDOTDIR to launch zsh with, or nil if the user already customizes `ZDOTDIR`
    /// themselves — don't interpose on a dotfile setup we don't understand — or the shim
    /// files couldn't be written.
    /// Only bails when ZDOTDIR points somewhere OTHER than $HOME: the shim's own .zshrc
    /// resets ZDOTDIR to $HOME as its last step (see `write()`), so a vidrio window
    /// launched from inside another vidrio window (e.g. running `swift run` in its
    /// terminal) inherits ZDOTDIR=$HOME from its parent shell — indistinguishable from the
    /// unset default, and must NOT be treated as a user's own custom dotfile setup.
    static func zdotdirIfSafe(currentEnvironment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let existing = currentEnvironment["ZDOTDIR"], existing != home {
            return nil
        }
        guard write() else { return nil }
        return dir
    }

    private static func write() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Always sourced by zsh, login or not.
            let zshenv = """
            [[ -f "$HOME/.zshenv" ]] && source "$HOME/.zshenv"
            """
            // Sourced for login shells, between .zshenv and .zshrc. ZDOTDIR must point back
            // at this shim afterwards or zsh would skip the .zshrc below. The user's .zlogin
            // needs no shim: it runs after .zshrc, which has already restored ZDOTDIR.
            let zprofile = """
            _vidrio_zdotdir="$ZDOTDIR"
            ZDOTDIR="$HOME"
            [[ -f "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
            ZDOTDIR="$_vidrio_zdotdir"
            unset _vidrio_zdotdir
            """
            // Sourced for interactive shells. Restores ZDOTDIR to $HOME first so anything
            // in the user's real .zshrc that reads it (rare, but some frameworks cache
            // paths off it) sees the normal value, not this shim directory.
            let zshrc = """
            ZDOTDIR="$HOME"
            [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
            [[ -n "$VIDRIO_PROMPT" ]] && PROMPT="$VIDRIO_PROMPT"
            # OSC 133;A marks where each prompt starts, for jumping between commands. It goes
            # inside PROMPT because zsh may still move to a new line after precmd, when the
            # last output didn't end in one. Re-added each time since themes rewrite PROMPT.
            autoload -Uz add-zsh-hook
            _vidrio_mark_prompt() {
              [[ $PROMPT == *$'\\e]133;A'* ]] || PROMPT=$'%{\\e]133;A\\a%}'$PROMPT
            }
            add-zsh-hook precmd _vidrio_mark_prompt
            """
            try zshenv.write(to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try zprofile.write(to: dir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
            try zshrc.write(to: dir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
