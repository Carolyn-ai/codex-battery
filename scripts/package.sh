#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
if [[ "${1:-}" != '--no-build' ]]; then /bin/zsh "$PROJECT_DIR/build.sh" --universal; fi
APP="$PROJECT_DIR/dist/Codex 电量管家.app"
codesign --verify --strict "$APP"
PACKAGE_DIR="$PROJECT_DIR/build/package/CodexBattery-1.5.2-macOS"
mkdir -p "$PROJECT_DIR/build/package" "$PROJECT_DIR/dist"
if [[ -d "$PACKAGE_DIR" ]]; then rm -rf "$PACKAGE_DIR"; fi
mkdir -p "$PACKAGE_DIR/dist" "$PACKAGE_DIR/scripts"
ditto "$APP" "$PACKAGE_DIR/dist/Codex 电量管家.app"
cp "$PROJECT_DIR/一键安装.command" "$PROJECT_DIR/install.sh" "$PROJECT_DIR/LICENSE" "$PACKAGE_DIR/"
cp "$PROJECT_DIR/scripts/install.sh" "$PACKAGE_DIR/scripts/install.sh"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/PRIVACY.md" "$PACKAGE_DIR/"
ZIP="$PROJECT_DIR/dist/CodexBattery-1.5.2-macOS.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$PACKAGE_DIR" "$ZIP"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "${ZIP:t}" > SHA256SUMS.txt)
print "已打包：$ZIP"
