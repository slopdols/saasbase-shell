#!/bin/bash
# Vercel Ignored Build Step.
# Only builds on the branches Vercel deploys from.
# Vercel semantics: exit 1 = build, exit 0 = skip (deployment CANCELED).
#
# Vercel deploys from:
#   - production: main
#   - preview:    dev
#
# FORCE_ALL=true in the environment bypasses the branch gate.
set -euo pipefail

BRANCH="${VERCEL_GIT_COMMIT_REF:-}"
FORCE="${FORCE_ALL:-false}"

if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "dev" ]; then
  echo "Building saasbase website for branch: $BRANCH"
  exit 1
fi

if [ "$FORCE" = "true" ]; then
  echo "FORCE_ALL=true -> building anyway"
  exit 1
fi

echo "Skipping website build for branch: $BRANCH"
exit 0
