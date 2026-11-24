#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
app="Build/Sluka's OCR Companion.app"
mkdir -p Build/ModuleCache "$app/Contents/MacOS" "$app/Contents/Resources/Reader" "$app/Contents/Resources/Licenses"

for arch in arm64 x86_64; do
  xcrun swiftc -O -whole-module-optimization -target "$arch-apple-macosx15.0" \
    -module-cache-path "$PWD/Build/ModuleCache" Sources/*.swift -o "Build/OCRCompanion-$arch"
done
lipo -create Build/OCRCompanion-arm64 Build/OCRCompanion-x86_64 -output "$app/Contents/MacOS/OCRCompanion"
cp Resources/* "$app/Contents/Resources/"
"Build/OCRCompanion-$(uname -m)" --compile-segmentation-dictionary \
  Resources/cedict_ts.u8 "$app/Contents/Resources/cedict.bin"
rm -f "$app/Contents/Resources/cedict_ts.u8"
cp Reader/* "$app/Contents/Resources/Reader/"
cp Licenses/* "$app/Contents/Resources/Licenses/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ocrcompanion.reader</string>
<key>CFBundleName</key><string>Sluka's OCR Companion</string>
<key>CFBundleDisplayName</key><string>Sluka's OCR Companion</string>
<key>CFBundleExecutable</key><string>OCRCompanion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>3.11.11</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
print "Built $app"
