import Foundation
import ScreenCaptureKit

enum WindowCapture {
    static func image(of window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let width = (window.frame.width * CGFloat(filter.pointPixelScale)).rounded(.up)
        let height = (window.frame.height * CGFloat(filter.pointPixelScale)).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 40_000_000 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "This window is too large. Capture a smaller screen area."])
        }
        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(height)
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.includeChildWindows = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
