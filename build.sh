#!/bin/bash
# Builds AudioViz.app (a bundle is required so macOS can ask for the system-audio permission).
# Usage: ./build.sh          build only
#        ./build.sh run      build and launch
#        ./build.sh install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AudioViz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AudioViz "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
    run)
        open "$APP"
        ;;
    install)
        pkill -x AudioViz 2>/dev/null || true
        rm -rf /Applications/AudioViz.app
        cp -R "$APP" /Applications/
        # Refresh the icon in Finder/Dock caches.
        touch /Applications/AudioViz.app
        echo "Installed /Applications/AudioViz.app"
        open /Applications/AudioViz.app
        ;;
esac
