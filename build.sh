#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$PROJECT_DIR/dist/Codex 电量管家.app"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 '需要 Apple Command Line Tools。请先运行 xcode-select --install，安装后再试。'
  exit 1
fi
mkdir -p "$BUILD_DIR" "$PROJECT_DIR/dist"
STAGING="$(mktemp -d "$BUILD_DIR/app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Codex 电量管家.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCHS=("$(uname -m)")
if [[ "${1:-}" == '--universal' ]]; then ARCHS=(arm64 x86_64); fi
for ARCH in "${ARCHS[@]}"; do
  xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos14.0" \
    -module-cache-path "$BUILD_DIR/module-cache-$ARCH" \
    -debug-prefix-map "$PROJECT_DIR"=/CodexBattery \
    -framework AppKit -parse-as-library "$PROJECT_DIR"/Source/*.swift \
    -o "$STAGING/CodexBattery-$ARCH"
done
if (( ${#ARCHS[@]} > 1 )); then
  xcrun lipo -create "$STAGING"/CodexBattery-* -output "$APP/Contents/MacOS/CodexBattery"
else
  cp "$STAGING/CodexBattery-${ARCHS[1]}" "$APP/Contents/MacOS/CodexBattery"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex-battery</string>
<key>CFBundleName</key><string>Codex 电量管家</string>
<key>CFBundleDisplayName</key><string>Codex 电量管家</string>
<key>CFBundleExecutable</key><string>CodexBattery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.2</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$PROJECT_DIR/docs/使用说明.md" "$APP/Contents/Resources/使用说明.md"
cp "$PROJECT_DIR/PRIVACY.md" "$APP/Contents/Resources/PRIVACY.md"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
if [[ -d "$APP_PATH" ]]; then rm -rf "$APP_PATH"; fi
ditto "$APP" "$APP_PATH"
print "已构建：$APP_PATH"
