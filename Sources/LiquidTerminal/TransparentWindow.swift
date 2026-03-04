import Cocoa

class TransparentWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let locationInWindow = event.locationInWindow
            // If the double-click is in the top 50 pixels (title bar area)
            if locationInWindow.y >= self.frame.height - 50 {
                self.zoom(nil)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
