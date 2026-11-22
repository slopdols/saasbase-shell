#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP/calls" "$TMP/output"; rmdir "$TMP"' EXIT
export AWS_TEST_LOG="$TMP/calls"
unset API_IMAGE_URI WEBSITE_URL ADMIN_SUB AWS_TEST_FAILURE APP_NAME DEPLOY_INFRASTRUCTURE
export AWS_REGION=us-east-2

aws() {
  printf 'CALL\n' >> "$AWS_TEST_LOG"
  printf '<%s>\n' "$@" >> "$AWS_TEST_LOG"
  case "$1 $2" in
    "sts get-caller-identity") echo 123456789012 ;;
    "s3api head-bucket")
      [[ " $* " == *" --expected-bucket-owner 123456789012 "* ]] || return 1
      if [ "${AWS_TEST_FAILURE:-}" = bucket ]; then
        echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2
        return 1
      fi
      if [[ "${AWS_TEST_FAILURE:-}" = bucket-race* ]]; then
        if ! grep -Fxq '<create-bucket>' "$AWS_TEST_LOG"; then
          echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
          return 1
        fi
        if [[ "$AWS_TEST_FAILURE" = bucket-race-verification ]]; then
          echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2
          return 1
        fi
      fi
      ;;
    "s3api create-bucket")
      if [[ "${AWS_TEST_FAILURE:-}" = bucket-race-new ]]; then return 0; fi
      if [[ "${AWS_TEST_FAILURE:-}" = bucket-race-owned || "${AWS_TEST_FAILURE:-}" = bucket-race-verification ]]; then
        echo "An error occurred (BucketAlreadyOwnedByYou) when calling the CreateBucket operation" >&2
        return 1
      fi
      echo "An error occurred (BucketAlreadyExists) when calling the CreateBucket operation" >&2
      return 1
      ;;
    "s3api put-public-access-block"|"s3api put-bucket-versioning") ;;
    "s3 sync") ;;
    "cloudformation deploy")
      if [[ "${AWS_TEST_FAILURE:-}" = deploy* ]]; then
        echo "mock deployment failed" >&2
        return 17
      fi
      ;;
    "cloudformation describe-stack-events")
      if [ "${AWS_TEST_FAILURE:-}" = deploy-diagnostics ]; then
        echo "mock event access denied" >&2
        return 9
      fi
      if [[ "$*" = *"--output text"* ]]; then
        echo arn:aws:cloudformation:us-east-2:123456789012:stack/saasbase-dev-Lambda/child
      elif [[ "$*" = *"/child"* ]]; then
        echo "Lambda CREATE_FAILED: image could not be accessed"
      else
        echo "Nested stack CREATE_FAILED"
      fi
      ;;
    "cloudformation list-exports")
      if [ "${AWS_TEST_FAILURE:-}" = exports ]; then
        echo "mock export lookup failed" >&2
        return 1
      fi
      echo https://example.execute-api.us-east-2.amazonaws.com
      ;;
    *) echo "Unexpected AWS call: $*" >&2; return 1 ;;
  esac
}
export -f aws

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_deploy() {
  : > "$AWS_TEST_LOG"
  bash "$DIR/scripts/deploy-stack.sh" "$@" > "$TMP/output" 2>&1
}

assert_arg() {
  grep -Fxq -- "<$1>" "$AWS_TEST_LOG" || fail "Missing argument: $1"
}

assert_no_arg_prefix() {
  if grep -Fq -- "<$1" "$AWS_TEST_LOG"; then
    fail "Unexpected argument prefix: $1"
  fi
}

assert_rejected() {
  local message="$1"
  shift
  if run_deploy "$@"; then fail "Expected rejection: $*"; fi
  grep -Fq -- "$message" "$TMP/output" || fail "Missing error: $message"
  [ ! -s "$AWS_TEST_LOG" ] || fail "Invalid input caused AWS calls"
}

# AWS deploy applies defaults on create and reuses omitted parameters on update.
run_deploy dev 1
assert_arg Stage=dev
assert_arg AppName=saasbase
assert_arg TemplatesBucket=saasbase-templates-123456789012-us-east-2
assert_no_arg_prefix DeployLambdas=
assert_no_arg_prefix ApiImageUri=
echo "PASS: phase 1 preserves compute parameters"

export API_IMAGE_URI=ignored-in-phase-one
run_deploy prod
assert_arg Stage=prod
assert_no_arg_prefix DeployLambdas=
assert_no_arg_prefix ApiImageUri=
echo "PASS: default phase ignores image overrides"

export APP_NAME=my-shell
run_deploy dev 1
assert_arg my-shell-dev
assert_arg AppName=my-shell
assert_arg TemplatesBucket=my-shell-templates-123456789012-us-east-2
echo "PASS: app-specific stack and bucket names"
export APP_NAME=Invalid
assert_rejected "Invalid APP_NAME" dev 1
unset APP_NAME
echo "PASS: invalid app name rejected"

export API_IMAGE_URI=123456789012.dkr.ecr.us-east-2.amazonaws.com/saasbase-api-prod:sha
export WEBSITE_URL='https://example.com/path with spaces'
export ADMIN_SUB=admin-sub
run_deploy prod 2
assert_arg DeployLambdas=true
assert_arg "ApiImageUri=$API_IMAGE_URI"
assert_arg "WebsiteUrl=$WEBSITE_URL"
assert_arg AdminSub=admin-sub
grep -Fq "Stack saasbase-prod deployed. Endpoint: https://" "$TMP/output" ||
  fail "Missing successful deployment output"
echo "PASS: phase 2 selects image and preserves argument boundaries"

export DEPLOY_INFRASTRUCTURE=false
run_deploy prod 2
assert_arg "ApiImageUri=$API_IMAGE_URI"
assert_no_arg_prefix TemplatesBucket=
assert_no_arg_prefix AppName=
assert_no_arg_prefix Stage=
assert_no_arg_prefix WebsiteUrl=
assert_no_arg_prefix AdminSub=
if grep -Fq '<s3' "$AWS_TEST_LOG"; then fail 'Image-only update uploaded or provisioned templates'; fi
echo "PASS: Image-only updates preserve infrastructure parameters and skip template operations"
assert_rejected "Phase 1 requires infrastructure deployment" dev 1
export DEPLOY_INFRASTRUCTURE=invalid
assert_rejected "DEPLOY_INFRASTRUCTURE must be true or false" dev 2
unset DEPLOY_INFRASTRUCTURE
echo "PASS: Invalid infrastructure modes stop before AWS calls"

assert_rejected "Invalid stage" staging 1
echo "PASS: invalid stage rejected"
assert_rejected "Invalid phase" dev 3
echo "PASS: invalid phase rejected"
unset API_IMAGE_URI
assert_rejected "API_IMAGE_URI is required for phase 2" dev 2
echo "PASS: missing phase-two image rejected before AWS calls"

export AWS_TEST_FAILURE=deploy
if run_deploy dev 1; then fail "Deployment failure was swallowed"; else status=$?; fi
[ "$status" -eq 17 ] || fail "Deployment exit status was changed"
grep -Fq "mock deployment failed" "$TMP/output" || fail "Missing deployment error"
grep -Fq "Lambda CREATE_FAILED: image could not be accessed" "$TMP/output" || fail "Nested failure reason was not printed"
assert_no_arg_prefix list-exports
if grep -Fq "deployed. Endpoint:" "$TMP/output"; then fail "False success output"; fi
echo "PASS: deployment failures propagate"

export AWS_TEST_FAILURE=deploy-diagnostics
if run_deploy dev 1; then fail "Failed diagnostics concealed deployment failure"; else status=$?; fi
[ "$status" -eq 17 ] || fail "Diagnostics replaced the deployment exit status"
grep -Fq "Could not retrieve stack failure events" "$TMP/output" || fail "Diagnostics failed silently"
assert_no_arg_prefix list-exports
echo "PASS: diagnostics failures preserve deployment failure and are surfaced"

export AWS_TEST_FAILURE=exports
if run_deploy dev 1; then fail "Export lookup failure was swallowed"; fi
grep -Fq "mock export lookup failed" "$TMP/output" || fail "Missing export lookup error"
if grep -Fq "deployed. Endpoint:" "$TMP/output"; then fail "False success output"; fi
echo "PASS: export lookup failures propagate"

export AWS_TEST_FAILURE=bucket
if run_deploy dev 1; then fail "Bucket access denial was swallowed"; fi
grep -Fq "Cannot inspect templates bucket" "$TMP/output" || fail "Missing bucket error"
assert_no_arg_prefix create-bucket
assert_no_arg_prefix deploy
echo "PASS: bucket access errors do not trigger creation or deployment"

export AWS_TEST_FAILURE=bucket-race-owned
run_deploy dev 1
assert_arg --expected-bucket-owner
assert_arg put-public-access-block
assert_arg put-bucket-versioning
assert_arg deploy
echo "PASS: Concurrent template-bucket creation verifies ownership and applies protection"

export AWS_TEST_FAILURE=bucket-race-new
run_deploy dev 1
assert_arg create-bucket
assert_arg LocationConstraint=us-east-2
assert_arg put-public-access-block
assert_arg put-bucket-versioning
echo "PASS: Fresh templates buckets are created and protected"

export AWS_TEST_FAILURE=bucket-race-verification
if run_deploy dev 1; then fail "Failed bucket ownership verification was ignored"; fi
assert_no_arg_prefix deploy
assert_no_arg_prefix put-public-access-block
echo "PASS: Failed concurrent bucket ownership verification blocks configuration and deployment"

export AWS_TEST_FAILURE=bucket-race-foreign
if run_deploy dev 1; then fail "Foreign bucket collision was ignored"; fi
grep -Fq 'Cannot create templates bucket' "$TMP/output" || fail "Missing bucket collision error"
assert_no_arg_prefix deploy
assert_no_arg_prefix put-public-access-block
echo "PASS: Concurrent foreign bucket collisions stop before configuration or deployment"
