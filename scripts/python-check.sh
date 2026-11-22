#!/usr/bin/env bash
# Backend quality gate: Python version + Ruff + Black + mypy strict.
# Invoked by scripts/test.ps1 and CI; fails the run on any violation.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/backend"

python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 13) else "Python >= 3.13 required")'
ruff check .
black --check .
mypy api
