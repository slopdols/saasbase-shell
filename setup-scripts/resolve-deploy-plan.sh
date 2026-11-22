#!/usr/bin/env bash
set -euo pipefail

declare -A flags=(
  [SKIP_ALL]=false
  [FORCE_ALL]=false
  [SKIP_DEPLOY_BACKEND]=false
  [SKIP_DEPLOY_WEBSITE]=false
  [FORCE_DEPLOY_BACKEND]=false
  [FORCE_DEPLOY_WEBSITE]=false
  [SKIP_TEST_INFRASTRUCTURE]=false
  [SKIP_TEST_BACKEND]=false
  [SKIP_TEST_WEBSITE_UNIT]=false
  [SKIP_TEST_WEBSITE_E2E]=false
  [SKIP_TEST_WEBSITE_AUTH]=false
  [SKIP_POST_DEPLOY_TESTS]=false
)
declare -A seen=()

if [[ -f config/override.env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$ ]]; then
      echo "::error::Invalid config/override.env entry; use an allowed KEY=true or KEY=false setting." >&2
      exit 1
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ ! ${flags[$key]+present} ]]; then
      echo "::error::Unsupported config/override.env setting." >&2
      exit 1
    fi
    if [[ ${seen[$key]+present} ]]; then
      echo "::error::Duplicate config/override.env setting." >&2
      exit 1
    fi
    seen[$key]=true
    flags[$key]=$value
  done < config/override.env
fi

if [[ "${flags[SKIP_ALL]}" != true && "${flags[FORCE_ALL]}" != true ]] &&
  { [[ "${flags[SKIP_DEPLOY_BACKEND]}" == true && "${flags[FORCE_DEPLOY_BACKEND]}" == true ]] ||
    [[ "${flags[SKIP_DEPLOY_WEBSITE]}" == true && "${flags[FORCE_DEPLOY_WEBSITE]}" == true ]]; }; then
  echo "::error::A deployment stage cannot be both skipped and forced." >&2
  exit 1
fi

head="${GITHUB_SHA:?GITHUB_SHA is required}"
before="${GITHUB_EVENT_BEFORE:-}"
initial_deployment=false
if [[ -z "$before" || "$before" =~ ^0+$ ]]; then
  # A first push to a branch or a manual run has no previous remote commit,
  # so every file counts as changed and the first deployment provisions.
  initial_deployment=true
  changed_files="$(git ls-tree -r --name-only "$head")"
else
  # Diff against the last remote commit, even when it is a root commit:
  # template-generated repositories start with a single root commit, so a
  # later push must not be mistaken for the initial deployment.
  changed_files="$(git diff --name-only "$before" "$head")"
fi

backend_changed=false
website_changed=false
infrastructure_changed=false
while IFS= read -r path; do
  case "$path" in
    iac/*) infrastructure_changed=true ;;
  esac
  case "$path" in
    backend/*|iac/*|aws/iam.json|.github/workflows/ci-cd.yml)
      backend_changed=true
      ;;
  esac
  case "$path" in
    website/*|setup-scripts/common.ps1|setup-scripts/publish-website.ps1|.github/workflows/ci-cd.yml)
      website_changed=true
      ;;
  esac
done <<< "$changed_files"

if [[ "${flags[SKIP_ALL]}" == true ]]; then
  deploy_backend=false
  deploy_website=false
elif [[ "${flags[FORCE_ALL]}" == true ]]; then
  deploy_backend=true
  deploy_website=true
else
  deploy_backend="$backend_changed"
  deploy_website="$website_changed"
  [[ "${flags[FORCE_DEPLOY_BACKEND]}" == true ]] && deploy_backend=true
  [[ "${flags[SKIP_DEPLOY_BACKEND]}" == true ]] && deploy_backend=false
  [[ "${flags[FORCE_DEPLOY_WEBSITE]}" == true ]] && deploy_website=true
  [[ "${flags[SKIP_DEPLOY_WEBSITE]}" == true ]] && deploy_website=false
fi

deploy_infrastructure=false
if [[ "$deploy_backend" == true ]] &&
  { [[ "$infrastructure_changed" == true ]] || [[ "$initial_deployment" == true ]] || [[ "${flags[FORCE_ALL]}" == true ]]; }; then
  deploy_infrastructure=true
fi

declare -A tests=()
for key in SKIP_TEST_INFRASTRUCTURE SKIP_TEST_BACKEND SKIP_TEST_WEBSITE_UNIT \
  SKIP_TEST_WEBSITE_E2E SKIP_TEST_WEBSITE_AUTH SKIP_POST_DEPLOY_TESTS; do
  name="${key#SKIP_}"
  tests["run_${name,,}"]=true
  if [[ "${flags[$key]}" == true ]]; then
    tests["run_${name,,}"]=false
    echo "::warning::$key enabled: this suite is skipped, not verified."
  fi
done
run_test_website=false
if [[ "${tests[run_test_website_unit]}" == true || "${tests[run_test_website_e2e]}" == true || "${tests[run_test_website_auth]}" == true ]]; then
  run_test_website=true
fi

{
  printf 'deploy_backend=%s\n' "$deploy_backend"
  printf 'deploy_website=%s\n' "$deploy_website"
  printf 'backend_changed=%s\n' "$backend_changed"
  printf 'website_changed=%s\n' "$website_changed"
  printf 'deploy_infrastructure=%s\n' "$deploy_infrastructure"
  printf 'infrastructure_changed=%s\n' "$infrastructure_changed"
  printf 'run_test_website=%s\n' "$run_test_website"
  for name in "${!tests[@]}"; do printf '%s=%s\n' "$name" "${tests[$name]}"; done
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

printf 'Deployment plan: infrastructure=%s, backend=%s (changed=%s), website=%s (changed=%s)\n' \
  "$deploy_infrastructure" "$deploy_backend" "$backend_changed" "$deploy_website" "$website_changed"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## Changes and overrides\n\nInfrastructure: %s; backend: %s; website: %s.\n\n' "$deploy_infrastructure" "$deploy_backend" "$deploy_website"
    for name in "${!tests[@]}"; do printf -- '- `%s`: %s\n' "$name" "${tests[$name]}"; done
    printf '\nDisabled suites are skipped, not verified. Offline flags do not change local acceptance requirements.\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
