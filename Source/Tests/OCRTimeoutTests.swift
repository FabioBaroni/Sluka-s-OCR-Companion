import Foundation

@main
struct OCRTimeoutTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        try Data().write(to: output)
        let sleeping = Process()
        sleeping.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeping.arguments = ["5"]
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try TesseractOCR.run(sleeping, outputFile: output, timeout: 0.2)
            preconditionFailure("Expected the OCR process to time out")
        } catch TesseractOCR.Error.timedOut {
            precondition(ProcessInfo.processInfo.systemUptime - started < 2)
        }

        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/echo")
        echo.arguments = ["next capture"]
        let text = try TesseractOCR.run(echo, outputFile: output, timeout: 1)
        precondition(String(decoding: text, as: UTF8.self) == "next capture\n")
        print("Passed subprocess timeout and immediate retry")

        let chinese = String(repeating: "今天学习汉语。", count: 81)
        let french = String(repeating: "Voilà le texte. ", count: 36) + "Dernier mot."
        let recognized = [chinese, french].map { ScreenCaptureLine(text: $0, bounds: nil, confidence: nil) }
        let sections = CapturedPassages.sections(in: recognized, limit: 400)
        precondition(sections.allSatisfy { $0.count <= 400 })
        precondition(sections.prefix(2).joined() == chinese)
        precondition(sections.dropFirst(2).joined(separator: " ") == french)
        precondition(sections.last?.hasSuffix("Dernier mot.") == true)
        print("Passed long Chinese and French capture sectioning, including the end of the window")
    }
}
