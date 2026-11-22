#!/usr/bin/env bash
# Ensures the S3 bucket that hosts the nested templates exists (versioned, private).
# Prints the bucket name to stdout.
set -euo pipefail

STAGE="${1:?usage: $0 <stage>}"
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${APP_NAME:-saasbase}-templates-${ACCOUNT}-${REGION}"

# head-bucket prints JSON to stdout on success in newer CLI versions, which
# would leak into the "$BUCKET" captured by the caller; keep stdout clean.
if HEAD_ERROR="$(aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" --expected-bucket-owner "$ACCOUNT" 2>&1)"; then
  echo "Bucket already exists: $BUCKET" >&2
else
  if [[ "$HEAD_ERROR" != *"(404)"* && "$HEAD_ERROR" != *"(NoSuchBucket)"* && "$HEAD_ERROR" != *"(NotFound)"* ]]; then
    printf 'Cannot inspect templates bucket %s: %s\n' "$BUCKET" "$HEAD_ERROR" >&2
    exit 1
  fi
  echo "Creating bucket: $BUCKET" >&2
  CREATE_ARGS=(--bucket "$BUCKET" --region "$REGION")
  if [ "$REGION" != "us-east-1" ]; then
    CREATE_ARGS+=(--create-bucket-configuration "LocationConstraint=$REGION")
  fi
  if CREATE_ERROR="$(aws s3api create-bucket "${CREATE_ARGS[@]}" 2>&1)"; then
    :
  elif [[ "$CREATE_ERROR" == *"(BucketAlreadyOwnedByYou)"* ]]; then
    aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" \
      --expected-bucket-owner "$ACCOUNT" >/dev/null
  else
    printf 'Cannot create templates bucket %s: %s\n' "$BUCKET" "$CREATE_ERROR" >&2
    exit 1
  fi
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled \
    >/dev/null
fi

echo "$BUCKET"
