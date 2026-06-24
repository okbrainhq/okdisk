#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="dev"
for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev) ENV="dev" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$ENV" == "prod" ]]; then
  APP="$ROOT/OKDisk.app"
else
  APP="$ROOT/OKDisk-Dev.app"
fi

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh" "--$ENV"
fi

if [[ "$ENV" == "dev" ]]; then
  open -n "$APP"
else
  open "$APP"
fi
