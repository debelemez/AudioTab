#!/bin/bash
# AudioTab derleme betiği
#   ./build.sh                 → AudioTab.app oluşturur (bu Mac'in işlemcisi için)
#   ./build.sh --install       → eski GlassTab/AudioHop'u kapatır, /Applications'a kurar ve açar
#   ./build.sh --universal     → Apple Silicon + Intel (GitHub Actions bunu kullanır)
#   ./build.sh --version 2.3.0 → sürüm numarası (verilmezse VERSION dosyasından)
# İmza: SIGN_IDENTITY ortam değişkeni verilirse o sertifikayla, yoksa ad-hoc imzalanır.
set -euo pipefail
cd "$(dirname "$0")"

APP="AudioTab.app"
ID="com.firewallstudio.audiotab"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
INSTALL=0
UNIVERSAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --version) VERSION="$2"; shift ;;
    *) echo "Bilinmeyen seçenek: $1"; exit 1 ;;
  esac
  shift
done

if ! command -v swiftc >/dev/null; then
  echo "❌ swiftc yok. Önce şunu çalıştır: xcode-select --install"
  exit 1
fi

xattr -cr . 2>/dev/null || true

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

compile() {   # $1 = mimari
  swiftc -O -wmo -swift-version 5 -parse-as-library \
    -target "$1-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework ApplicationServices -framework ServiceManagement \
    -framework CoreAudio -framework IOKit \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework ImageIO -framework UniformTypeIdentifiers -framework Security \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit \
    Sources/*.swift -o "$BUILD/AudioTab-$1" 2> "$BUILD/errors-$1.txt"
}

fail() {
  echo ""
  echo "❌ Derleme başarısız. Aşağıdaki hatayı kopyalayıp Claude'a gönder:"
  echo "----------------------------------------------------------------"
  grep -E "error:" "$BUILD"/errors-*.txt | head -30 || head -60 "$BUILD"/errors-*.txt
  exit 1
}

if [[ $UNIVERSAL == 1 ]]; then
  echo "▶ Derleniyor (arm64 + x86_64, sürüm $VERSION)..."
  compile arm64 || fail
  compile x86_64 || fail
  lipo -create "$BUILD/AudioTab-arm64" "$BUILD/AudioTab-x86_64" -output "$BUILD/AudioTab"
else
  ARCH="$(uname -m)"
  echo "▶ Derleniyor ($ARCH, sürüm $VERSION)..."
  compile "$ARCH" || fail
  mv "$BUILD/AudioTab-$ARCH" "$BUILD/AudioTab"
fi
strip -x "$BUILD/AudioTab" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/AudioTab" "$APP/Contents/MacOS/AudioTab"
chmod +x "$APP/Contents/MacOS/AudioTab"

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>AudioTab</string>
  <key>CFBundleDisplayName</key><string>AudioTab</string>
  <key>CFBundleExecutable</key><string>AudioTab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▶ İmzalanıyor (sertifika)..."
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$ID" --timestamp=none "$APP"
else
  codesign --force --sign - --identifier "$ID" "$APP"
fi
codesign --verify --strict "$APP" && echo "✔ İmza tamam"

if [[ $INSTALL == 1 ]]; then
  # Eski uygulamalar aynı kısayolları yakalamaya çalışmasın
  pkill -x GlassTab 2>/dev/null || true
  pkill -x AudioHop 2>/dev/null || true
  pkill -x AudioTab 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo ""
  echo "✅ /Applications/AudioTab.app kuruldu ve açıldı."
  for old in GlassTab AudioHop; do
    if [[ -d "/Applications/$old.app" ]]; then
      echo "⚠️  /Applications/$old.app hâlâ duruyor. Girişte açılıp çakışmasın diye çöpe at."
    fi
  done
else
  echo ""
  echo "✅ Hazır: $APP (sürüm $VERSION)"
fi
