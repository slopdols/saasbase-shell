#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
planner="$root/setup-scripts/resolve-deploy-plan.sh"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
export GITHUB_STEP_SUMMARY="$temp/step-summary.md"
cd "$temp"

git init -q -b main
git config user.name "Deployment Plan Test"
git config user.email "deployment-plan@example.invalid"
mkdir -p docs config
printf 'baseline\n' > docs/readme.txt
git add docs/readme.txt
git commit -q -m baseline
git commit -q --allow-empty -m "baseline ready"
base="$(git rev-parse HEAD)"

run_plan() {
  local before="$1"
  local head="$2"
  local expected_backend="$3"
  local expected_website="$4"
  local expected_infrastructure="${5:-false}"
  local output
  local summary="$temp/step-summary.md"
  output="$(mktemp)"
  : > "$summary"
  GITHUB_EVENT_BEFORE="$before" GITHUB_SHA="$head" GITHUB_OUTPUT="$output" \
    bash "$planner"
  grep -Fxq "deploy_backend=$expected_backend" "$output"
  grep -Fxq "deploy_website=$expected_website" "$output"
  grep -Fxq "deploy_infrastructure=$expected_infrastructure" "$output"
  [[ "$(grep -Fc '## Changes and overrides' "$summary")" == 1 ]]
  rm -f "$output"
}

mkdir -p backend
printf 'api change\n' > backend/change.py
git add backend/change.py
git commit -q -m "backend change"
backend_commit="$(git rev-parse HEAD)"
run_plan "$base" "$backend_commit" true false

mkdir -p website/src
printf 'frontend change\n' > website/src/change.js
printf 'SKIP_DEPLOY_WEBSITE=true\n' > config/override.env
git add website/src/change.js config/override.env
git commit -q -m "website change with skip"
website_commit="$(git rev-parse HEAD)"
run_plan "$backend_commit" "$website_commit" false false

printf 'FORCE_ALL=true\nSKIP_DEPLOY_BACKEND=true\nSKIP_DEPLOY_WEBSITE=true\n' > config/override.env
git add config/override.env
git commit -q -m "force all"
force_all_commit="$(git rev-parse HEAD)"
run_plan "$website_commit" "$force_all_commit" true true true

printf 'SKIP_ALL=true\nFORCE_ALL=true\n' > config/override.env
git add config/override.env
git commit -q -m "skip all"
skip_all_commit="$(git rev-parse HEAD)"
run_plan "$force_all_commit" "$skip_all_commit" false false

printf 'FORCE_DEPLOY_WEBSITE=true\n' > config/override.env
printf 'documentation change\n' > docs/readme.txt
git add config/override.env docs/readme.txt
git commit -q -m "force website"
force_website_commit="$(git rev-parse HEAD)"
run_plan "$skip_all_commit" "$force_website_commit" false true

printf 'SKIP_DEPLOY_BACKEND=true\nFORCE_DEPLOY_BACKEND=true\n' > config/override.env
git add config/override.env
git commit -q -m "conflicting stage flags"
output="$(mktemp)"
if GITHUB_EVENT_BEFORE="$force_website_commit" GITHUB_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$output" \
  bash "$planner" >/dev/null 2>&1; then
  echo "Expected conflicting stage flags to fail." >&2
  exit 1
fi
rm -f "$output"

printf '' > config/override.env
mkdir -p iac
printf 'template change\n' > iac/main.yaml
git add iac/main.yaml config/override.env
git commit -q -m "infrastructure change"
run_plan "$force_website_commit" "$(git rev-parse HEAD)" true false true
echo 'PASS: IaC changes select provisioning; backend-only changes do not'

for key in SKIP_TEST_INFRASTRUCTURE SKIP_TEST_BACKEND SKIP_TEST_WEBSITE_UNIT \
  SKIP_TEST_WEBSITE_E2E SKIP_TEST_WEBSITE_AUTH SKIP_POST_DEPLOY_TESTS; do
  printf '%s=true\nFORCE_DEPLOY_BACKEND=true\n' "$key" > config/override.env
  output="$(mktemp)"
  GITHUB_EVENT_BEFORE="$(git rev-parse HEAD)" GITHUB_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$output" bash "$planner"
  grep -Fxq 'deploy_backend=true' "$output"
  grep -Fxq 'deploy_infrastructure=false' "$output"
  for candidate in SKIP_TEST_INFRASTRUCTURE SKIP_TEST_BACKEND SKIP_TEST_WEBSITE_UNIT \
    SKIP_TEST_WEBSITE_E2E SKIP_TEST_WEBSITE_AUTH SKIP_POST_DEPLOY_TESTS; do
    result=true
    [[ "$key" == "$candidate" ]] && result=false
    name="${candidate#SKIP_}"
    grep -Fxq "run_${name,,}=$result" "$output"
  done
  rm -f "$output"
done
printf 'SKIP_TEST_WEBSITE_UNIT=true\nSKIP_TEST_WEBSITE_E2E=true\nSKIP_TEST_WEBSITE_AUTH=true\n' > config/override.env
output="$(mktemp)"
GITHUB_EVENT_BEFORE="$(git rev-parse HEAD)" GITHUB_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$output" bash "$planner"
grep -Fxq 'run_test_website=false' "$output"
rm -f "$output"
echo 'PASS: Per-suite and post-deployment skip flags are independent of deployment'

for invalid in 'SKIP_TEST_BACKEND=maybe' 'SKIP_TEST_UNKNOWN=true' \
  $'SKIP_TEST_BACKEND=true\nSKIP_TEST_BACKEND=false' 'SKIP_TEST_BACKEND=$(touch injected)'; do
  printf '%s\n' "$invalid" > config/override.env
  output="$(mktemp)"
  if GITHUB_EVENT_BEFORE="$(git rev-parse HEAD)" GITHUB_SHA="$(git rev-parse HEAD)" GITHUB_OUTPUT="$output" \
    bash "$planner" >/dev/null 2>&1; then
    echo 'Expected invalid test override to fail.' >&2
    exit 1
  fi
  [[ ! -s "$output" && ! -f injected ]]
  rm -f "$output"
done
echo 'PASS: Invalid test overrides fail before publishing a plan'

mkdir template-start
cd template-start
git init -q -b main
git config user.name "Deployment Plan Test"
git config user.email "deployment-plan@example.invalid"
mkdir backend website
printf 'api\n' > backend/app.txt
printf 'spa\n' > website/app.txt
git add backend website
git commit -q -m "template root commit"
template_root="$(git rev-parse HEAD)"

# Template-generated repos keep a root commit as their last remote commit;
# non-infrastructure changes after it must not trigger provisioning.
printf 'api tweak\n' >> backend/app.txt
git add backend/app.txt
git commit -q -m "backend change after template root"
backend_after_root="$(git rev-parse HEAD)"
run_plan "$template_root" "$backend_after_root" true false

printf 'app notes\n' > readme.txt
git add readme.txt
git commit -q -m "docs after backend change"
docs_after_backend="$(git rev-parse HEAD)"
run_plan "$backend_after_root" "$docs_after_backend" false false

# Only infrastructure changes trigger full provisioning.
mkdir iac
printf 'template change\n' > iac/main.yaml
git add iac/main.yaml
git commit -q -m "infrastructure change"
iac_change="$(git rev-parse HEAD)"
run_plan "$template_root" "$iac_change" true false true

# A missing or all-zero previous commit is the first deployment: provision everything.
run_plan "" "$iac_change" true true true
run_plan "0000000000000000000000000000000000000000" "$iac_change" true true true

# Overrides still apply when the previous remote commit is a root commit.
mkdir config
printf 'SKIP_DEPLOY_WEBSITE=true\n' > config/override.env
run_plan "$template_root" "$iac_change" true false true
rm -f config/override.env

# Joining an unchanged tree leaves nothing to deploy.
git checkout -q --orphan cloned-shell
git add backend website iac readme.txt
git commit -q -m "cloned shell history"
git merge -q --allow-unrelated-histories --strategy=ours -m "join template history" "$iac_change"
joined="$(git rev-parse HEAD)"
[[ -z "$(git diff --name-only "$iac_change" "$joined")" ]]
run_plan "$iac_change" "$joined" false false

printf 'documentation change\n' > readme.txt
git add readme.txt
git commit -q -m "docs after first deployment"
run_plan "$joined" "$(git rev-parse HEAD)" false false
echo 'PASS: Root-commit bases diff normally; only IaC changes trigger provisioning'
