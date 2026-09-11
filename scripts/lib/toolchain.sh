#!/bin/bash
# AiOS local toolchain contract.
#
# This file is sourced by all local build/test entry points. It deliberately selects
# the Xcode 27 beta inside this repo only; it never changes the Mac-wide xcode-select
# setting. Override AIOS_XCODE_APP or AIOS_DEVELOPER_DIR for a different compatible
# Xcode installation during a controlled upgrade.

AIOS_XCODE_APP="${AIOS_XCODE_APP:-/Applications/Xcode-beta-b4.app}"
AIOS_DEVELOPER_DIR="${AIOS_DEVELOPER_DIR:-$AIOS_XCODE_APP/Contents/Developer}"

if [ ! -x "$AIOS_DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "AiOS toolchain error: Xcode developer directory is unavailable:" >&2
  echo "  $AIOS_DEVELOPER_DIR" >&2
  echo "Set AIOS_XCODE_APP or AIOS_DEVELOPER_DIR to a compatible Xcode 27 installation." >&2
  return 2 2>/dev/null || exit 2
fi

export DEVELOPER_DIR="$AIOS_DEVELOPER_DIR"
AIOS_XCODEBUILD="$AIOS_DEVELOPER_DIR/usr/bin/xcodebuild"
AIOS_SWIFT="$AIOS_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

if [ ! -x "$AIOS_SWIFT" ]; then
  echo "AiOS toolchain error: Swift is unavailable at $AIOS_SWIFT" >&2
  return 2 2>/dev/null || exit 2
fi

aios_print_toolchain() {
  echo "AiOS developer directory: $DEVELOPER_DIR"
  "$AIOS_XCODEBUILD" -version
  "$AIOS_SWIFT" --version
}
