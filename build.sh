#!/bin/bash
# Builds Cellar as a Universal app (native Apple Silicon + Intel) and wraps it into Cellar.app.
#   ./build.sh            -> build/Cellar.app
#   ./build.sh --install  -> also copies it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

# If this Terminal is running under Rosetta, re-run the whole script natively on Apple Silicon.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
  echo "==> This Terminal is running under Rosetta (Intel mode). Re-running natively…"
  exec arch -arm64 /bin/bash "$0" "$@"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Xcode, or just the Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

MIN_MACOS="13.0"
ARCHS=(arm64 x86_64)
SLICES=()

for ARCH in "${ARCHS[@]}"; do
  echo "==> Compiling for ${ARCH}..."
  TRIPLE="${ARCH}-apple-macosx${MIN_MACOS}"
  swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH"
  BIN_DIR="$(swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH" --show-bin-path)"
  SLICES+=("$BIN_DIR/Cellar")
done

APP="build/Cellar.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Cellar"
cp -R Resources/. "$APP/Contents/Resources/"
# The DirectX 12 runtime ships one large library compressed.
if [[ -f "$APP/Contents/Resources/d3d12/moltenvk/libmetalirconverter.dylib.gz" ]]; then
  gunzip -f "$APP/Contents/Resources/d3d12/moltenvk/libmetalirconverter.dylib.gz"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cellar</string>
  <key>CFBundleDisplayName</key><string>Cellar</string>
  <key>CFBundleIdentifier</key><string>local.cellar.app</string>
  <key>CFBundleExecutable</key><string>Cellar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSArchitecturePriority</key>
  <array><string>arm64</string><string>x86_64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, for this Mac only)"
codesign --force --sign - "$APP" >/dev/null

echo "==> Architectures in the app: $(lipo -archs "$APP/Contents/MacOS/Cellar")"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Cellar.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "==> Installed to ~/Applications/Cellar.app"
fi

echo
echo "Done. Launch it with:"
echo "  open \"$APP\""
