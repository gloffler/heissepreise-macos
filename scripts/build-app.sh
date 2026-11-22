#!/bin/zsh
# Builds a release binary and wraps it into build/HeissePreise.app (ad-hoc signed).
# Works with the Command Line Tools alone – no Xcode project required.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product HeissePreise
BIN="$(swift build -c release --show-bin-path)/HeissePreise"

APP="build/HeissePreise.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeissePreise"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Heiße Preise</string>
    <key>CFBundleDisplayName</key><string>Heiße Preise</string>
    <key>CFBundleIdentifier</key><string>io.heisse-preise.mac</string>
    <key>CFBundleExecutable</key><string>HeissePreise</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.shopping</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"
