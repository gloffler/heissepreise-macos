#!/bin/zsh
# Builds a release binary and wraps it into build/HeissePreise.app (ad-hoc signed).
# Works with the Command Line Tools alone – no Xcode project required.
#
#   ./scripts/build-app.sh            # version from the latest git tag (vX.Y.Z), else 0.0.0
#   ./scripts/build-app.sh 1.2.0      # explicit version
#
# The build number is the commit count, so every commit yields a higher CFBundleVersion.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>HPGitCommit</key><string>${COMMIT}</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.shopping</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 gloffler · MIT License · Daten: heisse-preise.io</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP  (version $VERSION, build $BUILD, $COMMIT)"
