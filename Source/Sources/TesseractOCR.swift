import AppKit

enum TesseractOCR {
    enum Error: Swift.Error { case timedOut }
    private static let languageData = ["el": "ell", "fi": "fin", "ar": "ara", "th": "tha", "uk": "ukr",
        "vi": "vie", "id": "ind", "ro": "ron", "da": "dan", "no": "nor", "pl": "pol", "sv": "swe",
        "nl": "nld", "tr": "tur", "ru": "rus", "ko": "kor", "ja": "jpn", "fr": "fra", "es": "spa",
        "pt": "por", "de": "deu", "it": "ita", "en": "eng", "zh-Hans": "chi_sim", "zh-Hant": "chi_tra"]

    private static func installation(for language: String) -> (URL, URL, String)? {
        guard let model = languageData[language] else { return nil }
        let files = FileManager.default
        for path in ["/opt/homebrew", "/usr/local"] {
            let prefix = URL(fileURLWithPath: path)
            let executable = prefix.appendingPathComponent("bin/tesseract")
            let data = prefix.appendingPathComponent("share/tessdata")
            if files.isExecutableFile(atPath: executable.path),
               files.isReadableFile(atPath: data.appendingPathComponent(model + ".traineddata").path) {
                return (executable, data, model)
            }
        }
        return nil
    }

    static func supports(_ language: String) -> Bool { installation(for: language) != nil }

    static func recognize(_ image: CGImage, language: String) throws -> [ScreenCaptureLine] {
        guard let (executable, data, model) = installation(for: language),
              let input = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OCRCompanion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageFile = folder.appendingPathComponent("screen.png")
        try input.write(to: imageFile)
        let process = Process()
        process.executableURL = executable
        process.arguments = [imageFile.path, "stdout", "--tessdata-dir", data.path, "-l", model, "--psm", "6"]
        let outputFile = folder.appendingPathComponent("text")
        try Data().write(to: outputFile)
        let output = try run(process, outputFile: outputFile, timeout: 12)
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map {
            ScreenCaptureLine(text: String($0), bounds: nil, confidence: nil)
        }
    }

    static func run(_ process: Process, outputFile: URL, timeout: TimeInterval) throws -> Data {
        let file = try FileHandle(forWritingTo: outputFile)
        defer { try? file.close() }
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw Error.timedOut
        }
        guard process.terminationStatus == 0 else { return Data() }
        return try Data(contentsOf: outputFile)
    }

}
