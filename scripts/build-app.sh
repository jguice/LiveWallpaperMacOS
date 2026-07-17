#!/usr/bin/env bash
#
# Build LiveWallpaper.app (the app plus its embedded wallpaperdaemon) and
# install it. There is no CI for this fork, so this script is the reproducible
# local build/release path.
#
# It Release-builds both Xcode targets into ./build-xcode (gitignored), then
# installs the .app into /Applications and strips the Gatekeeper quarantine
# (the build is unsigned, so first launch would otherwise be blocked).
#
# Usage:
#   scripts/build-app.sh              # build + install to /Applications
#   scripts/build-app.sh --no-install # build only; leaves .app in ./build-xcode
#
# Env overrides:
#   DEVELOPER_DIR   full Xcode toolchain (default: /Applications/Xcode.app/Contents/Developer)
#   INSTALL_DIR     install destination  (default: /Applications)
#   CONFIGURATION   Debug | Release      (default: Release)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
: "${INSTALL_DIR:=/Applications}"
: "${CONFIGURATION:=Release}"
export DEVELOPER_DIR

PROJECT="LiveWallpaper.xcodeproj"
DERIVED="$REPO_ROOT/build-xcode"
APP_NAME="LiveWallpaper.app"
BUILT_APP="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME"

INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "error: xcodebuild not found under DEVELOPER_DIR=$DEVELOPER_DIR" >&2
  echo "       Install full Xcode (not just Command Line Tools), or set DEVELOPER_DIR." >&2
  exit 1
fi

echo "==> Checking out submodules (yaml-cpp)"
git submodule update --init --recursive

# The shared LiveWallpaper scheme builds the wallpaperdaemon target before the
# app target (parallelizeBuildables=NO), so the app's CopyFiles phase finds the
# daemon in the products dir. The app declares no explicit target dependency, so
# the scheme's build order is what makes this deterministic.
echo "==> Building LiveWallpaper ($CONFIGURATION)"
xcodebuild -project "$PROJECT" -scheme LiveWallpaper -configuration "$CONFIGURATION" \
           -derivedDataPath "$DERIVED" -destination "platform=macOS" \
           CODE_SIGNING_ALLOWED=NO build

[ -d "$BUILT_APP" ] || { echo "error: build did not produce $BUILT_APP" >&2; exit 1; }
echo "==> Built $BUILT_APP"

if [ "$INSTALL" -eq 0 ]; then
  echo "==> Skipped install (--no-install)."
  exit 0
fi

DEST="$INSTALL_DIR/$APP_NAME"
echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$BUILT_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST"
echo "==> Installed $DEST (unsigned, quarantine stripped)."
echo "    Launch it and pick a wallpaper; launchd then owns the daemon."
