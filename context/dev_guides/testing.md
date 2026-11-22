# Testing the Shell and New Features

Follow [coding-rules.md](coding-rules.md). Product acceptance criteria live in
[business requirements](../business_logic/); tests prove the implementation meets
them. Every feature needs unit, integration/API and browser coverage at its
applicable layers, including meaningful errors and authorization boundaries.

## Full local acceptance

Prepare the development toolchain using [README.md](../../README.md#run-all-local-tests):
Python 3.13, Node 22, PowerShell 7.2+, Bash, backend dev requirements, frontend npm
dependencies, Chromium and the CI-pinned cfn-lint version.
On Windows use Git Bash, not an unconfigured WSL launcher.

From the repository root:

```powershell
./scripts/test.ps1
```

```sh
bash ./scripts/test.sh
```

The runner executes all PowerShell setup/operation/publishing/API-runner
regressions, Bash deployment/planner/installer checks, all backend pytest cases,
the backend quality gates (Python version, Ruff, Black and mypy strict), frontend
unit tests, both local browser suites, a production frontend build and
CloudFormation schema lint. It fails on missing tools or failed checks.
It does not install dependencies, call live APIs or delete cloud resources.

The runner restores its working directory and `CI` environment setting after
completion or failure. During browser tests `CI=true` prevents accidental reuse
of unrelated local servers. Do not skip suites to make a feature look complete.
Planner and PowerShell script fixtures redirect `GITHUB_STEP_SUMMARY` to temporary
test files, so repeated planner/publishing regressions never append mock reports
to the real Actions summary. Planner checks assert one summary section per invocation.
Setup regressions verify both branch pipelines launch before any completion wait.
Publisher tests cover bounded Production readiness waits, timeout/error propagation
and no Preview uploads/alias changes on timeout. Infrastructure tests cover
concurrent same-account templates-bucket creation and rejected foreign collisions.
Purge regressions cover absent repos/projects, recorded workspace/token reuse,
paginated workspace selection and provider access errors without cloud mutation.
They also reject reported missing GitHub `delete_repo` scopes before cloud changes
and verify that final repository deletion denials preserve incomplete recovery
state and permit retry after authorization is corrected.
Confirmed-purge cases cover continued AWS/provider deletion after S3/secret/
Vercel errors, the complete final failure journal, retry after GitHub is gone,
already-disabled workflow races, blocked foreign AWS inventory, and historical
nested-stack membership when `RootId` is missing. Ordinary destroy keeps its
fail-fast regressions; no test weakens ownership or active-deployment gates.
Installer regressions require Git executable mode (`100755`) on every tracked
`.sh` script, so fresh Linux/macOS clones support direct execution without `chmod`.
Preserve this mode when adding scripts, including from Windows:
`git update-index --chmod=+x -- path/to/script.sh`.

## Suite ownership and focused commands

| Suite | Files | Focused command |
|---|---|---|
| Backend units/helpers | `backend/tests/core/` | `python -m pytest --import-mode=importlib tests/core` from `backend` |
| Backend quality gates | `scripts/python-check.sh`, `scripts/python-check.ps1` | `bash scripts/python-check.sh` (or `pwsh -File scripts/python-check.ps1`) from root |
| Business services | `backend/tests/services/` | `python -m pytest --import-mode=importlib tests/services` from `backend` |
| Storage integration | `backend/tests/crud/` | `python -m pytest --import-mode=importlib tests/crud` from `backend` |
| HTTP/API/auth | `backend/tests/routers/` | `python -m pytest --import-mode=importlib tests/routers` from `backend` |
| Deployment runner | `backend/tests/test_deployment_runner.py` | `python -m pytest --import-mode=importlib tests/test_deployment_runner.py` from `backend` |
| Frontend units | `website/tests/unit/` | `npm run test:unit` from `website` |
| Mock-first browser workflows | `website/e2e/`, excluding native-auth/deployed tests | `npm run test:e2e` from `website` |
| Native-auth browser workflows | `website/e2e/auth.spec.js` | `npm run test:e2e:auth` from `website` |
| PowerShell script regressions | `setup-scripts/tests/` | `pwsh -File setup-scripts/tests/run-tests.ps1` from root |
| Infrastructure script regressions | `iac/tests/` | `bash iac/tests/test-deploy-stack.sh` from root |
| Deployment selection/installers | `setup-scripts/tests/` | `bash setup-scripts/tests/test-deploy-plan.sh` and `bash setup-scripts/tests/test-install-tools.sh` from root |

Use focused selectors during implementation, then run the full acceptance entry
point. Keep new tests in the owning suite; feature subfolders are fine when the
existing runner discovers them. A new separate suite must be wired into both
[scripts/test.ps1](../../scripts/test.ps1) and
[ci-cd.yml](../../.github/workflows/ci-cd.yml).

## Fixtures and what local tests prove

Backend [conftest.py](../../backend/tests/conftest.py) provides isolated moto
DynamoDB tables, a real FastAPI TestClient and locally signed JWT/JWKS fixtures.
Reuse `ApiEnv` and its authentication helper instead of creating another identity
or storage harness. These cases verify the HTTP/service/storage path, not AWS
permissions or a deployed Cognito pool. Keep `--import-mode=importlib`: router
and service test files intentionally share basenames.

Frontend unit tests use Vitest/jsdom and existing store/client fixtures.
Mock-first browser tests start the development website, normally on port 8080.
The native-auth config uses a separate server, normally port 8081, disables the
app's backend mocks and intercepts API/Cognito responses in the browser fixture.
It exercises real forms and session code, but is still not live authentication.
`PLAYWRIGHT_PORT` overrides the local port if needed.

Do not rely on an already-running website with unknown environment variables.
Fix port conflicts or choose a free port; do not terminate unrelated processes.
Never point local fixtures at customer accounts to compensate for a missing mock.

## What to add for a feature

1. Write observable acceptance criteria in the applicable business document;
   document new test/developer procedures here or in a focused subfolder.
2. Add a focused regression that fails without the implementation. Reuse existing
   fixtures and test outputs, not private implementation details.
3. Get-or-create paths (settings, identities, configuration records) must include
   a conflict/race regression: concurrent first reads/create attempts produce
   exactly one record and one winner; the losing caller receives the existing
   record without field loss or version corruption.
4. For an API-backed feature, cover units/services/storage and the real FastAPI
   HTTP contract: status, response fields/values, validation, unauthenticated
   requests, wrong-owner/role access and stale versions where applicable.
5. Cover frontend state/client behavior plus browser loading, empty, success and
   error states, navigation and permissions. Update local mocks with the actual
   API contract; do not let mocks hide missing backend behavior.
6. Extend the deployed API/browser path for critical cross-system behavior.
   Preserve per-run data isolation, explicit failure and cleanup.
7. Update requirement/orientation links, run all local suites and report actual
   results. Explain genuinely inapplicable layers; do not add trivial tests just
   to claim every category is covered.
8. Before handoff, diff the business documents against the implemented contract
   (endpoints, fields, lifecycle, reveal rules) and report disagreements. Any
   observable behavior change must have updated the owning business document or
   opened an explicit outstanding-decision item in the same change.

The sample [item API tests](../../backend/tests/routers/test_items.py) illustrate
201 creation, 401 missing identity, 403 wrong owner, 404 missing/deleted items,
409 stale updates and soft deletion. Adapt those patterns to a feature's actual
contract rather than assuming every endpoint has the same behavior.

DynamoDB pagination regressions cover table/GSI results beyond 1 MB, empty
intermediate pages, exact continuation keys and later-page failures. Service/API
tests force one-item database batches and verify that later active items are
returned while deleted/other-owner items are excluded. The client response
remains an array; no frontend paging behavior or mock contract changes are needed.

## Live deployment acceptance

After a selected deployment succeeds, CI's **Test deployed website and API** job runs
[test-deployment.py](../../setup-scripts/test-deployment.py):
PowerShell [API contracts](../../setup-scripts/test-shell.ps1), then
[deployed Playwright](../../website/e2e/deployed/). Public checks run on both
stages; authenticated API/browser checks are required on dev when the job runs.
Production requires `RUN_AUTH_SMOKE_TESTS=true` in its GitHub environment.
Setting that flag false cannot disable authenticated dev checks.
`SKIP_POST_DEPLOY_TESTS=true` in `config/override.env` explicitly skips the entire
live job on either stage, including its API suite and browsers. It defaults off.

The workflow supplies HTTPS `API_URL`/`WEBSITE_URL`, `STAGE`, `AWS_REGION`,
Cognito issuer/client ID and the dev Vercel automation bypass.
API item timestamp checks preserve the original JSON strings: UTC `Z` and
`+00:00` are valid, but nonzero/missing offsets and invalid dates fail. PowerShell's
automatic conversion of `+00:00` to local `DateTime` must not alter that contract.
The orchestrator creates a temporary non-admin Cognito user, masks its generated
credentials, sets them only in child environments and deletes the user in
`finally`. It suppresses email delivery; it does not test real inbox verification.
The test role needs the current Cognito admin-create/password/delete permissions.
Do not replace this with a shared persistent password or customer account.

API tests clean up only their own item through soft deletion; its DynamoDB row
remains. Forced runner termination can interrupt cleanup and leave test data/users.
Do not claim cleanup in that case. Browser traces/screenshots/videos are disabled
for live credentials, and the bypass header is restricted to the configured
website origin, never the API/Cognito.

`npm run test:e2e:deployed` alone does not provision a user or run the API suite.
Test discovery with `--list` proves selection/syntax, not a working deployment.
Use the configured workflow for normal live acceptance. Manual runs require
explicit environment/account authorization and the same isolation rules.
Tests must never charge customers, send messages or mutate their data.

## Verifying CI/CD results after a push

The `gh` CLI is available to the coding session, so inspect the run for the commit
you pushed instead of asking the owner to describe it. Confirm access with
`gh auth status`; the token needs the `repo` scope to read runs, jobs and logs and
the `workflow` scope to dispatch or rerun workflows. If the CLI is missing,
unauthenticated or lacks a scope, ask the owner to authorize the session with
`gh auth login` or `gh auth refresh -s repo,workflow`. Do not request, paste or
store a token, and do not treat an inaccessible run as passing.

```sh
git rev-parse HEAD
gh run list --branch dev --commit "$(git rev-parse HEAD)"
gh run view <run-id>
gh run view <run-id> --log-failed
```

Inspect the actual jobs and steps. A run URL, a green badge or the absence of a
failure message is not verification. Confirm that the expected offline suites ran
and, for a deployment, that `deploy` and **Test deployed website and API**
actually executed instead of reporting `skipped`. Use
[ci-cd-debugging.md](ci-cd-debugging.md) for skip interpretation, AWS/Lambda log
correlation, rerun authorization and the failure report template.

## Checks and failure reporting

- **Check changes and overrides** runs first and reads only allowed boolean
  settings from `config/override.env`; it never executes that file.
  CI's offline jobs run by default regardless of changed folders. The user can
  explicitly skip infrastructure/script tests, backend pytest, frontend units,
  local browsers or native-auth browsers independently using the flags in
  [README](../../README.md#pipeline-overrides). Deployment flags do not skip tests.
  Initial setup rejects all enabled test/deployment skips, and the local full-suite
  runner never honors them. Skipped suites are reported as unverified.
  PRs do not deploy. Documentation-only changes may skip
  deployment, so a green PR is not evidence of live verification.
- Missing imports/tools: install the declared requirements/runtime prerequisite
  from README, then rerun the failed check; do not weaken tests.
- Playwright startup failures: inspect the configured server/port and toolchain,
  not just the test selector. Authentication challenges, unexpected payloads and
  cleanup failures must surface as failures.
- Backend quality gates are **enforced by the full runner and CI**: after backend
  pytest, `scripts/python-check.sh` verifies the interpreter satisfies
  `requires-python` (>= 3.13) and runs Ruff, Black `--check` and mypy strict,
  failing the run on any violation. Use the same script for standalone checks;
  skipped gates are not passed gates.
- Report the command, suite/result, environment/commit and the inspected Actions
  run (id/URL, jobs/steps and conclusions) for live evidence, and remaining gaps.
  Naming a run, sharing its link or showing a green badge without inspecting its
  jobs is not evidence. Coverage percentages, mocks and successful builds are not
  substitutes for behavioral acceptance.

## Browser flake policy

- Playwright configs retry once only under `CI=true` (GitHub Actions and the
  full local runner): each failed mock-first/native-auth test retries once.
  Standalone focused commands run without `CI` and keep `retries = 0`, so a
  flake can be reproduced deterministically outside load.
- A test that fails on its retry attempt is a real defect. Reproduce it
  standalone with the focused command from the suite table, then fix or report
  it; do not dismiss failures as load noise without evidence.
- Skips remain forbidden: never mark a flaky test skipped to make a suite green.
