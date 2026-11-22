#!/usr/bin/env bash
# Uploads the nested templates to s3://<bucket>/<stage>/templates/
set -euo pipefail

STAGE="${1:?usage: $0 <stage> <bucket>}"
BUCKET="${2:?usage: $0 <stage> <bucket>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Uploading templates to s3://$BUCKET/$STAGE/templates/"
aws s3 sync "$DIR/templates" "s3://$BUCKET/$STAGE/templates" --exclude '*.md' --quiet
echo "Upload complete."
