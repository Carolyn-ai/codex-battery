#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
exec /bin/zsh "$PROJECT_DIR/scripts/install.sh" "$@"
