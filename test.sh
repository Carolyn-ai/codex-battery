#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"
mkdir -p "$TEST_BUILD_DIR"
export CHENGYIN_EVENT_ROOT="$(mktemp -d "$TEST_BUILD_DIR/chengyin-events.XXXXXX")"
trap 'rm -rf "$CHENGYIN_EVENT_ROOT"' EXIT
for TEST_NAME in UsageModelsTests UsageClientTests ResetCountdownTests TiboResetMonitorTests TiboAlertTests ResetAnnouncementTimeTests TiboPostLinkTests; do
  SOURCE_FILES=("$PROJECT_DIR/Source/UsageModels.swift")
  if [[ "$TEST_NAME" == "UsageClientTests" ]]; then
    SOURCE_FILES+=("$PROJECT_DIR/Source/UsageClient.swift")
  fi
  if [[ "$TEST_NAME" == "ResetCountdownTests" ]]; then
    SOURCE_FILES=("$PROJECT_DIR/Source/ResetCountdown.swift")
  fi
  if [[ "$TEST_NAME" == "TiboResetMonitorTests" ]]; then
    SOURCE_FILES=("$PROJECT_DIR/Source/TiboResetMonitor.swift" "$PROJECT_DIR/Source/ResetAnnouncementTime.swift")
  fi
  if [[ "$TEST_NAME" == "TiboAlertTests" ]]; then
    SOURCE_FILES=("$PROJECT_DIR/Source/TiboResetMonitor.swift" "$PROJECT_DIR/Source/TiboAlert.swift" "$PROJECT_DIR/Source/ResetAnnouncementTime.swift")
  fi
  if [[ "$TEST_NAME" == "ResetAnnouncementTimeTests" ]]; then
    SOURCE_FILES=("$PROJECT_DIR/Source/ResetAnnouncementTime.swift")
  fi
  if [[ "$TEST_NAME" == "TiboPostLinkTests" ]]; then
    SOURCE_FILES=("$PROJECT_DIR/Source/TiboPostLink.swift")
  fi
  xcrun swiftc -module-cache-path "$TEST_BUILD_DIR/module-cache" \
    "${SOURCE_FILES[@]}" "$PROJECT_DIR/Tests/$TEST_NAME.swift" -o "$TEST_BUILD_DIR/$TEST_NAME"
  "$TEST_BUILD_DIR/$TEST_NAME"
done

/bin/zsh "$PROJECT_DIR/build.sh"
APP_BINARY="$PROJECT_DIR/dist/Codex 电量管家.app/Contents/MacOS/CodexBattery"
"$APP_BINARY" --self-test-interaction
"$APP_BINARY" --self-test-features
PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_DIR/Tests/test_install.py"
