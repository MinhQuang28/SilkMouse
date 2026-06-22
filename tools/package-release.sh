#!/bin/bash
# Package a QmouseFix release: build the .app, zip it, compute its sha256, and patch the Homebrew
# cask. Publishing to GitHub is opt-in (--publish) so this never makes an outward-facing change by
# accident. Usage:
#   tools/package-release.sh            # build + zip + sha256 + update cask (local only)
#   tools/package-release.sh --publish  # also create the GitHub release and upload the zip
set -euo pipefail

cd "$(dirname "$0")/.."

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

APP_NAME="QmouseFix"
CASK="Casks/qmousefix.rb"
# Single source of truth for the version: read it straight out of build-app.sh.
VERSION="$(awk -F'"' '/^VERSION=/ {print $2; exit}' build-app.sh)"
[ -n "$VERSION" ] || { echo "error: could not read VERSION from build-app.sh" >&2; exit 1; }
TAG="v${VERSION}"

APP="build/${APP_NAME}.app"
ZIP="dist/${APP_NAME}.zip"

echo "==> building ${APP_NAME} ${VERSION}"
./build-app.sh

echo "==> zipping ${APP} -> ${ZIP}"
mkdir -p dist
rm -f "$ZIP"
# ditto --keepParent preserves the .app bundle structure and code signature (plain `zip` can mangle it).
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256: ${SHA}"

echo "==> patching ${CASK} (version + sha256)"
sed -i '' -E "s|^  version \".*\"|  version \"${VERSION}\"|" "$CASK"
sed -i '' -E "s|^  sha256 .*|  sha256 \"${SHA}\"|"          "$CASK"

if [ "$PUBLISH" -eq 1 ]; then
    command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
    echo "==> creating GitHub release ${TAG} and uploading ${ZIP}"
    # --generate-notes auto-builds release notes from merged commits; clobber re-uploads on re-run.
    gh release create "$TAG" "$ZIP" --title "$TAG" --generate-notes 2>/dev/null \
        || gh release upload "$TAG" "$ZIP" --clobber
    echo "==> published: $(gh release view "$TAG" --json url -q .url)"
else
    cat <<EOF

==> done (local). Next steps:
    1. Review the cask diff:        git diff ${CASK}
    2. Publish the release:         tools/package-release.sh --publish
    3. Copy ${CASK} into your tap (MinhQuang28/homebrew-tap) to install via:
         brew install --cask minhquang28/tap/qmousefix
EOF
fi
