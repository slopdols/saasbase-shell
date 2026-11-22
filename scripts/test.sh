#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec pwsh -NoProfile -File "$root/scripts/test.ps1" "$@"
