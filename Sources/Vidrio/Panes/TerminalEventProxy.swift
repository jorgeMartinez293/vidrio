import Cocoa
import SwiftTerm

/// Sits between SwiftTerm's view and its default delegate to screen what programs ask for.
/// SwiftTerm's handlers for links and the clipboard are not overridable from outside its
/// module, so this forwards everything else untouched and filters those two.
@MainActor
final class TerminalEventProxy: @preconcurrency TerminalViewDelegate {
    private unowned let view: LocalProcessTerminalView
    var onOpenLink: ((String) -> Void)?
    var onClipboardWrite: ((Data) -> Void)?
    var onBell: (() -> Void)?
    /// What's on screen changed: new output, or the view scrolled.
    var onContentChanged: (() -> Void)?

    init(view: LocalProcessTerminalView) {
        self.view = view
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        onClipboardWrite?(content)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
        onBell?()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view.scrolled(source: source, position: position)
        onContentChanged?()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
        onContentChanged?()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
