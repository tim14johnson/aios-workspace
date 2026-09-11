#!/bin/bash
# Run an AiOS command using the repository's Xcode 27 toolchain without changing xcode-select.
# Usage:
#   bash tools/with-xcode27.sh scripts/verify.sh core
#   bash tools/with-xcode27.sh xcodebuild -version
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/toolchain.sh
source "$REPO/scripts/lib/toolchain.sh"

if [ "$#" -eq 0 ]; then
  aios_print_toolchain
  exit 0
fi

exec "$@"
