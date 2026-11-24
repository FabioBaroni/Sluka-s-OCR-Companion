import AppKit

@main
struct AreaSelectionTests {
    @MainActor static func main() {
        let view = AreaView(frame: CGRect(x: 0, y: 0, width: 400, height: 250))
        let event = { (kind: NSEvent.EventType, x: CGFloat, y: CGFloat) in
            NSEvent.mouseEvent(with: kind, location: CGPoint(x: x, y: y), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 0)!
        }
        let down = event(.leftMouseDown, 220, 180)
        precondition(view.acceptsFirstMouse(for: down))
        var result: AreaView.Result?
        view.onFinish = { result = $0 }
        view.mouseDown(with: down)
        view.mouseDragged(with: event(.leftMouseDragged, 150, 140))
        view.mouseUp(with: event(.leftMouseUp, 90, 50))
        guard case .area(let rectangle) = result else { preconditionFailure("Expected a capture rectangle") }
        precondition(rectangle == CGRect(x: 90, y: 50, width: 130, height: 130))

        view.mouseDown(with: event(.leftMouseDown, 20, 20))
        view.mouseUp(with: event(.leftMouseUp, 22, 22))
        guard case .tooSmall = result else { preconditionFailure("Expected feedback for a click-sized selection") }
        print("Passed first mouse, reverse drag, and small selection feedback")
    }
}
