#!/bin/zsh
# Builds the app for a given version and packages it for a GitHub release:
#   dist/HeissePreise-<version>-macOS-arm64.zip  (+ .sha256)
#
#   ./scripts/package-release.sh 1.0.0
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: package-release.sh <version, e.g. 1.0.0>}"
./scripts/build-app.sh "$VERSION"

mkdir -p dist
ZIP="dist/HeissePreise-${VERSION}-macOS-arm64.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle structure, symlinks and code signature intact.
ditto -c -k --sequesterRsrc --keepParent build/HeissePreise.app "$ZIP"
(cd dist && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")

echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1))"
cat "$ZIP.sha256"
