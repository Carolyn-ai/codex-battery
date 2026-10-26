#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/dist/Codex 电量管家.app"
IDENTIFIER='local.codex-battery'
DRY_RUN=0
NO_OPEN=0
DESTINATION=''
BACKUP_DIR=''
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-open) NO_OPEN=1; shift ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    *) print -u2 "不支持的参数：$1"; exit 2 ;;
  esac
done
if [[ -z "$DESTINATION" ]]; then
  EXISTING=()
  for ROOT in "$HOME/Applications" /Applications; do
    for APP in "$ROOT"/*.app(N); do
      BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
      if [[ "$BUNDLE_ID" == "$IDENTIFIER" ]]; then EXISTING+=("$APP"); fi
    done
  done
  if (( ${#EXISTING[@]} > 1 )); then print -u2 '发现多个旧版安装，请先核对重复应用。'; exit 1; fi
  DESTINATION="${EXISTING[1]:-$HOME/Applications/Codex 电量管家.app}"
fi
if [[ "$DESTINATION" != /* || "${DESTINATION:e}" != app ]]; then
  print -u2 '安装位置必须是绝对路径，且以 .app 结尾。'; exit 1
fi
if [[ -e "$DESTINATION" ]]; then
  OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$OLD_ID" != "$IDENTIFIER" ]]; then print -u2 '安装位置已有其他应用，已保留原件。'; exit 1; fi
  if [[ ! "$OLD_VERSION" =~ '^1\.' ]]; then
    print -u2 '已有不同主版本，停止安装以免降级覆盖。请保留原版，在其他 macOS 用户中体验此独立版。'; exit 1
  fi
fi
if (( DRY_RUN )); then
  print "检查模式：将安装到 $DESTINATION"
  print '不会复制应用、修改设置或启动程序。'
  exit 0
fi
if [[ ! -x "$SOURCE/Contents/MacOS/CodexBattery" ]]; then
  /bin/zsh "$PROJECT_DIR/build.sh"
fi
codesign --verify --strict "$SOURCE"
SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
[[ "$SOURCE_ID" == "$IDENTIFIER" ]] || { print -u2 '源应用身份不符。'; exit 1; }
mkdir -p "${DESTINATION:h}"
STAGING="$(mktemp -d "${DESTINATION:h}/.codex-battery-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$SOURCE" "$STAGING/Codex 电量管家.app"
codesign --verify --strict "$STAGING/Codex 电量管家.app"
if [[ -e "$DESTINATION" ]]; then
  [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$HOME/Library/Application Support/Codex Battery Backups/$(date +%Y%m%d_%H%M%S)-$$"
  mkdir -p "$BACKUP_DIR/Application"
  ditto "$DESTINATION" "$BACKUP_DIR/Application/${DESTINATION:t}"
  for RELATIVE in 'Preferences/local.codex-battery.plist' 'LaunchAgents/local.codex-battery.plist' 'Application Support/Codex Battery'; do
    if [[ -e "$HOME/Library/$RELATIVE" ]]; then
      mkdir -p "$BACKUP_DIR/${RELATIVE:h}"
      ditto "$HOME/Library/$RELATIVE" "$BACKUP_DIR/$RELATIVE"
    fi
  done
  # Stop only this installed bundle. Do not stop Codex or another copy by process name.
  /usr/bin/pkill -TERM -f "^${DESTINATION}/Contents/MacOS/CodexBattery$" 2>/dev/null || true
  mv "$DESTINATION" "$STAGING/previous.app"
fi
mv "$STAGING/Codex 电量管家.app" "$DESTINATION"
print "已安装：$DESTINATION"
if [[ -n "$BACKUP_DIR" ]]; then print "原版与设置备份：$BACKUP_DIR"; fi
if (( ! NO_OPEN )); then /usr/bin/open "$DESTINATION"; fi
