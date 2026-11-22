#!/usr/bin/env bash
# Deploys/updates the Saasbase master stack.
#
# Usage:
#   ./deploy-stack.sh <stage> <phase>
#     stage : dev | prod
#     phase : 1 (bootstrap/update, preserving compute) | 2 (Lambda + API Gateway)
#
# Env overrides (optional):
#   APP_NAME        resource prefix (default: saasbase)
#   API_IMAGE_URI   ECR image URI for the Lambda (required for phase 2)
#   WEBSITE_URL     canonical website URL
#   ADMIN_SUB       Cognito sub of the admin user
#   DEPLOY_INFRASTRUCTURE false selects an image-only phase 2 using existing templates/parameters
set -euo pipefail

STAGE="${1:?usage: $0 <stage> <phase:1|2>}"
PHASE="${2:-1}"
APP="${APP_NAME:-saasbase}"
STACK="${APP}-${STAGE}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-2}"
INFRASTRUCTURE="${DEPLOY_INFRASTRUCTURE:-true}"

if [[ ! "$APP" =~ ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ ]]; then
  echo "Invalid APP_NAME: use 3-24 lowercase letters, digits or hyphens; start with a letter and end with a letter or digit" >&2
  exit 1
fi
export APP_NAME="$APP"

case "$STAGE" in
  dev|prod) ;;
  *) echo "Invalid stage: $STAGE (expected dev or prod)" >&2; exit 1 ;;
esac
case "$PHASE" in
  1) ;;
  2)
    if [ -z "${API_IMAGE_URI:-}" ]; then
      echo "API_IMAGE_URI is required for phase 2" >&2
      exit 1
    fi
    ;;
  *) echo "Invalid phase: $PHASE (expected 1 or 2)" >&2; exit 1 ;;
esac
if [[ "$INFRASTRUCTURE" != true && "$INFRASTRUCTURE" != false ]]; then
  echo "DEPLOY_INFRASTRUCTURE must be true or false" >&2
  exit 1
fi
if [[ "$PHASE" == 1 && "$INFRASTRUCTURE" == false ]]; then
  echo "Phase 1 requires infrastructure deployment" >&2
  exit 1
fi

# 1) Ensure + upload templates
PARAMS=()
if [[ "$INFRASTRUCTURE" == true ]]; then
  BUCKET="$(bash "$DIR/scripts/ensure-templates-bucket.sh" "$STAGE")"
  bash "$DIR/scripts/upload-templates.sh" "$STAGE" "$BUCKET"
  PARAMS=("Stage=$STAGE" "AppName=$APP" "TemplatesBucket=$BUCKET")
else
  echo "Updating the Lambda image using existing infrastructure templates and parameters."
fi

# 2) Build parameter overrides
# Omitted parameters use template defaults on create and previous values on update.
# Phase 1 must never turn off compute or replace its existing image.
if [ "$PHASE" = "2" ]; then
  PARAMS+=("DeployLambdas=true" "ApiImageUri=$API_IMAGE_URI")
fi
if [[ "$INFRASTRUCTURE" == true ]]; then
  if [ -n "${WEBSITE_URL:-}" ]; then PARAMS+=("WebsiteUrl=$WEBSITE_URL"); fi
  if [ -n "${ADMIN_SUB:-}" ]; then PARAMS+=("AdminSub=$ADMIN_SUB"); fi
fi

echo "Deploying stack $STACK (phase $PHASE)"
if aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$DIR/main.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "${PARAMS[@]}" \
  --no-fail-on-empty-changeset; then
  :
else
  status=$?
  echo "Deployment failed for $STACK. Recent failed CloudFormation events:" >&2
  events_query="StackEvents[?contains(ResourceStatus, 'FAILED')].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]"
  if ! aws cloudformation describe-stack-events --region "$REGION" --stack-name "$STACK" \
    --max-items 50 --query "$events_query" --output table >&2; then
    echo "Could not retrieve stack failure events; inspect $STACK in CloudFormation." >&2
  fi
  if nested=$(aws cloudformation describe-stack-events --region "$REGION" --stack-name "$STACK" \
    --max-items 50 --query "StackEvents[?ResourceType=='AWS::CloudFormation::Stack' && contains(ResourceStatus, 'FAILED')].PhysicalResourceId" --output text); then
    for child in $nested; do
      if [[ "$child" != "arn:aws:cloudformation:$REGION:"* ]]; then continue; fi
      echo "Failed nested stack: $child" >&2
      if ! aws cloudformation describe-stack-events --region "$REGION" --stack-name "$child" \
        --max-items 50 --query "$events_query" --output table >&2; then
        echo "Could not retrieve nested stack failure events: $child" >&2
      fi
    done
  else
    echo "Could not identify failed nested stacks." >&2
  fi
  exit "$status"
fi

ENDPOINT="$(aws cloudformation list-exports --region "$REGION" --query "Exports[?Name=='$APP-$STAGE-api-endpoint'].Value" --output text)"
echo "Stack $STACK deployed. Endpoint: $ENDPOINT"
