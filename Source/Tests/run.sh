#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}/.."
mkdir -p Build/ModuleCache
node --check Reader/reader.js
node Tests/reader.test.cjs
node Tests/sluka-observer.test.cjs
node Tests/sluka-controls.test.cjs
xcrun swiftc -module-cache-path Build/ModuleCache Sources/ReaderServer.swift Sources/SlukaCommands.swift Sources/ScreenGeometry.swift Tests/ReaderPolicyTests.swift -o Build/policy-tests
Build/policy-tests
xcrun swiftc -module-cache-path Build/ModuleCache Sources/ReadingLanguage.swift Tests/ReadingLanguageTests.swift -o Build/language-tests
Build/language-tests
xcrun swiftc -module-cache-path Build/ModuleCache Sources/TesseractOCR.swift Sources/CaptureResult.swift Tests/OCRTimeoutTests.swift -o Build/timeout-tests
Build/timeout-tests
xcrun swiftc -module-cache-path Build/ModuleCache Sources/AreaSelection.swift Tests/AreaSelectionTests.swift -o Build/area-tests
Build/area-tests
study_app=Build/SlukaStudyTests.app/Contents
mkdir -p "$study_app/MacOS" "$study_app/Resources/Reader"
cp Reader/* "$study_app/Resources/Reader/"
study_sources=(Sources/*.swift)
study_sources=(${study_sources:#Sources/App.swift})
xcrun swiftc -target "$(uname -m)-apple-macosx15.0" -module-cache-path Build/ModuleCache \
  ${study_sources:#Sources/Chip.swift} Tests/SlukaStudyTests.swift -o "$study_app/MacOS/SlukaStudyTests"
"$study_app/MacOS/SlukaStudyTests"
