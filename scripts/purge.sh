#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
bash "$root/setup-scripts/install-tools.sh"
exec pwsh -NoProfile -File "$root/scripts/purge.ps1" "$@"
