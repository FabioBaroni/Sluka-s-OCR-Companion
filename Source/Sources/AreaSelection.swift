import AppKit

@MainActor final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor final class AreaView: NSView {
    var from: NSPoint?
    var to: NSPoint?
    enum Result { case area(NSRect), tooSmall, cancelled }

    var onFinish: ((Result) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill()
        if let from, let to {
            let rect = NSRect(x: min(from.x,to.x), y:min(from.y,to.y), width:abs(to.x-from.x), height:abs(to.y-from.y))
            NSColor.white.withAlphaComponent(0.12).setFill(); rect.fill()
            NSColor.systemGreen.setStroke(); let path=NSBezierPath(rect:rect); path.lineWidth=2; path.stroke()
        }
        let label = "Drag around text • Escape to cancel"
        label.draw(at: NSPoint(x:24,y:bounds.height-50), withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.boldSystemFont(ofSize:19)])
    }
    override func mouseDown(with event: NSEvent) { from=convert(event.locationInWindow,from:nil); to=from; needsDisplay=true }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        to=NSPoint(x:max(0,min(bounds.width,point.x)),y:max(0,min(bounds.height,point.y))); needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with:event)
        guard let from, let to else { onFinish?(.tooSmall); return }
        let rect=NSRect(x:min(from.x,to.x),y:min(from.y,to.y),width:abs(to.x-from.x),height:abs(to.y-from.y))
        onFinish?(rect.width >= 12 && rect.height >= 12 ? .area(rect) : .tooSmall)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onFinish?(.cancelled) } }
}

