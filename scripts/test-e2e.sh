#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_HOME="$ROOT/.build/swiftpm-home"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_HOME"

swift run OKDiskE2ETests
