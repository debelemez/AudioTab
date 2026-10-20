#!/bin/bash
# AudioTab'ı GitHub'daki son sürümden kur (derlemeye gerek yok):
#   curl -fsSL https://raw.githubusercontent.com/debelemez/AudioTab/main/install.sh | bash
set -euo pipefail
REPO="debelemez/AudioTab"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▶ Son sürüm indiriliyor..."
curl -fsSL "https://github.com/$REPO/releases/latest/download/AudioTab.zip" -o "$TMP/AudioTab.zip"
ditto -x -k "$TMP/AudioTab.zip" "$TMP"

for app in GlassTab AudioHop AudioTab; do pkill -x "$app" 2>/dev/null || true; done
sleep 0.5
rm -rf /Applications/AudioTab.app
ditto "$TMP/AudioTab.app" /Applications/AudioTab.app
xattr -dr com.apple.quarantine /Applications/AudioTab.app 2>/dev/null || true
open /Applications/AudioTab.app

echo "✅ AudioTab kuruldu. Bundan sonraki sürümler uygulamanın içinden güncellenir."
