import Foundation
import CoreGraphics
struct ScreenCrop {
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}
struct ScreenGeometry {
    static func centeredFrame(_ size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    static func isMovingThroughHoverGap(_ point: CGPoint, from previous: CGPoint, source: CGPoint, edge: CGPoint) -> Bool {
        let dx = edge.x - source.x, dy = edge.y - source.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return false }
        let x = point.x - source.x, y = point.y - source.y
        let progress = (x * dx + y * dy) / length
        let lateral = abs(x * dy - y * dx) / length
        let advance = ((point.x - previous.x) * dx + (point.y - previous.y) * dy) / length
        return progress > 0 && progress <= length + 8 && lateral <= 14 && advance > 0.75
    }

    static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cursorRegion(at point: CGPoint, within frame: CGRect, compact: Bool = false) -> CGRect {
        let width = min(compact ? 480 : 880, frame.width)
        let height = min(compact ? 144 : 340, frame.height)
        let x = min(max(point.x - width / 2, frame.minX), frame.maxX - width)
        let y = min(max(point.y - height / 2, frame.minY), frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func imageSize(for bounds: CGSize, scale: CGFloat) -> CGSize? {
        guard [bounds.width, bounds.height, scale].allSatisfy(\.isFinite),
              bounds.width >= 12, bounds.height >= 12, scale > 0 else { return nil }
        let sizeFactor = min(scale, 20_000 / bounds.width, 20_000 / bounds.height, sqrt(40_000_000 / bounds.width / bounds.height))
        let width = (bounds.width * sizeFactor).rounded(.down)
        let height = (bounds.height * sizeFactor).rounded(.down)
        guard width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Maps AppKit window-local points to top-left image pixels after a full-window capture.
    static func windowImageCrop(_ region: CGRect, windowSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard [region.minX, region.minY, region.width, region.height, windowSize.width, windowSize.height,
               imageSize.width, imageSize.height].allSatisfy(\.isFinite),
              windowSize.width >= 12, windowSize.height >= 12, imageSize.width > 0, imageSize.height > 0,
              region.width >= 12, region.height >= 12,
              CGRect(origin: .zero, size: windowSize).contains(region) else { return nil }
        let xScale = imageSize.width / windowSize.width
        let yScale = imageSize.height / windowSize.height
        let pixels = CGRect(x: region.minX * xScale, y: (windowSize.height - region.maxY) * yScale,
                            width: region.width * xScale, height: region.height * yScale)
        return pixels.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func screenBounds(forNormalizedFrame frame: CGRect, in capture: CGRect) -> CGRect {
        CGRect(x: capture.minX + frame.minX * capture.width, y: capture.minY + frame.minY * capture.height,
               width: frame.width * capture.width, height: frame.height * capture.height)
    }

    static func pixelCropScreenBounds(_ pixels: CGRect, imageSize: CGSize, in window: CGRect) -> CGRect {
        let normalized = CGRect(x: pixels.minX / imageSize.width, y: 1 - pixels.maxY / imageSize.height,
                                width: pixels.width / imageSize.width, height: pixels.height / imageSize.height)
        return screenBounds(forNormalizedFrame: normalized, in: window)
    }

    static func sentence(in sample: String, atUTF16Offset offset: Int) -> String? {
        guard let index = characterIndex(in: sample, atUTF16Offset: offset) else { return nil }
        let separators: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n", "\r", "\r\n"]
        let start = sample[..<index].lastIndex(where: { separators.contains($0) }).map { sample.index(after: $0) } ?? sample.startIndex
        let boundary = sample[index...].firstIndex(where: { separators.contains($0) })
        let end = boundary.map { sample.index(after: $0) } ?? sample.endIndex
        let sentence = sample[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    static func characterIndex(in text: String, atUTF16Offset offset: Int) -> String.Index? {
        let value = text as NSString
        guard offset >= 0, offset < value.length else { return nil }
        return Range(value.rangeOfComposedCharacterSequence(at: offset), in: text)?.lowerBound
    }

    static func crop(_ region: CGRect, displaySize: CGSize, scale: CGFloat) -> ScreenCrop? {
        guard [region.minX,region.minY,region.width,region.height,displaySize.width,displaySize.height,scale].allSatisfy({$0.isFinite}),
              region.minX>=0,region.minY>=0,region.width>=12,region.height>=12,scale>0,scale<=4,
              region.maxX<=displaySize.width,region.maxY<=displaySize.height else { return nil }
        let width=(region.width*scale).rounded(.up),height=(region.height*scale).rounded(.up)
        guard width<=20000,height<=20000,width*height<=40_000_000 else { return nil }
        return ScreenCrop(sourceRect:CGRect(x:region.minX,y:displaySize.height-region.maxY,width:region.width,height:region.height),pixelWidth:Int(width),pixelHeight:Int(height))
    }
}
