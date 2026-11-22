#!/usr/bin/env bash
# Runs `aws cloudformation validate-template` on every template.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

for f in "$DIR"/main.yaml "$DIR"/templates/*.yaml; do
  echo "Validating $(basename "$f")"
  if ! out="$(aws cloudformation validate-template --template-body "file://$f" 2>&1)"; then
    echo "  -> INVALID: $f"
    printf '%s\n' "$out" | sed 's/^/     /'
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "Template validation FAILED ($FAILED template(s))."
  exit 1
fi
echo "All templates valid."
