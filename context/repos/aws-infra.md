# AWS Infrastructure - saasbase

Stack: **CloudFormation nested stacks** (one template per AWS service),
orchestrated by `iac/main.yaml` with two-phase provisioning.
For account onboarding, use [setup.md](../../setup.md) and the PowerShell scripts
in `setup-scripts/`. Root `setup.ps1`/`setup.sh` launchers install missing tools
(WinGet on Windows, Homebrew on macOS, apt/official installers on Ubuntu/Debian).
Vault modules install on demand when the user saves a token.
Missing AWS profiles are configured through browser login or the SSO wizard.
Setup checks available profiles before inspecting SSO keys; malformed AWS
configuration still fails rather than being treated as a new profile.
The wizard creates app-specific OIDC deployment permissions,
GitHub environments and one Vercel project: `main` uses Production, `dev` uses
protected Preview. AWS stacks remain separate for prod and dev.
Before creating the GitHub repo, setup checks existing app stacks and
exact-name orphan resources, including the templates bucket and legacy/repository-ID
deployment roles. Any collision hard-fails and asks for another name; setup
never deletes/reuses resources. The separate `scripts/purge.ps1`/`scripts/purge.sh` command
accepts an app name and explicit account/region/team selection, inventories
AWS/GitHub/Vercel targets, requires irreversible-deletion confirmation,
drains CI, deletes AWS and Vercel, then deletes the GitHub repository last.
Purge reuses AWS teardown checks and saves `.setup/purge-*.json` for safe retries.
Confirmed purge collects independent AWS resource and provider deletion errors
instead of stopping on the first failure. GitHub is attempted last even if
AWS/Vercel cleanup is incomplete; the final report and journal retain target
IDs/errors. Ordinary destroy and setup checks still fail fast. Foreign ownership,
busy/replaced resources and unverified inventory are never bypassed; a failed
AWS inventory leaves AWS untouched but permits separately verified provider cleanup.
Deleted nested stacks missing `RootId` can be verified through historical parent
CloudFormation inventories; unavailable or foreign ancestry is rejected with
resource/stack IDs. Workflow shutdown skips disabled states and verifies races.
IAM roles are global to the selected account. Shared OIDC, unrelated
names, backups and Vercel remain outside preflight deletion.
For a new installation, setup creates an empty private repository,
adds a CI-skipped initialization commit while preserving the clone's files/history, switches origin
without moving or renaming the existing folder, so VS Code can stay open.
After deployment it reminds the user to rename the local folder manually.
Its initialization commit includes `[skip ci]`; main is pushed and dev is created
at that same commit without triggering push-based CI. GitHub template generation
is not used, so the app has no "generated from template" metadata.
Once configured, setup dispatches main and dev before waiting for either run.
The workflows are branch-concurrent; tests, AWS stacks and builds run in parallel.
Shared templates-bucket creation handles an already-owned concurrent creation by
rechecking account ownership and applying private/versioned settings; foreign
collisions and other AWS errors still fail. Only Preview upload waits (20 minutes
maximum) for the first ready Production website. Both deployments
must pass, including actual backend/frontend steps and smoke checks, before
setup reports success and prints their URLs. Failures stop setup, not the other
already-running pipeline; inspect both printed Actions links.
All offline unit/API/integration/browser suites run by default before deployment;
explicit per-suite CI overrides do not replace full local feature acceptance.
The separate **Test deployed website and API** job adds real browser/API tests and creates/deletes a temporary
non-admin Cognito user for dev (Production requires explicit opt-in). Its admin
user-test permissions are account/region scoped; it uses only the exported pool.
Testing details and local suite entry points are in [README.md](../../README.md).
The changes/override job runs before tests. It detects IaC changes separately from
backend/website changes. Backend-only deployments skip phase 1 and template
uploads; phase 2 changes only image-related parameters through CloudFormation,
preserving managed image state and existing infrastructure parameters/templates.
Only `iac/` changes trigger full provisioning on ordinary pushes. The detector
diffs against the previous remote commit, even when it is a template-generated
root commit, so non-IaC pushes never re-provision. Initial/manual deployments
and `FORCE_ALL` still perform full provisioning.
`SKIP_POST_DEPLOY_TESTS=true` explicitly disables the whole live job; all skips
default off and setup refuses them during initial onboarding.
Each setup invocation requires an unused repository name; existing repositories
always fail, even after partial setup. Saved state is for teardown/smoke configuration,
not setup recovery. Divergent
branches are rejected, not force-pushed. Both AWS environments incur charges.
The source repository is resolved from Git origin. Application repository
metadata is verified explicitly, and pushes use its exact URL. Template targets
are rejected before configuration/deployment. Old state cannot bypass the
unused-name check or change the new application repository target.
Vercel project names include the GitHub repository ID. Matching app/project-ID
names block setup before repo creation; exact-name races also fail afterward.
An optional password-protected PowerShell SecretStore vault reuses the Vercel
token on Windows, macOS and Linux.
Purge uses that same token helper and reuses the original workspace from matching
setup state or an unfinished purge record. Without a configured workspace it
shares setup's paginated team discovery and numbered selection. Missing remote
repos/projects do not block AWS cleanup. Confirmed independent deletion failures
are aggregated; failed identity/ownership checks never authorize unverified targets.

`scripts/destroy.ps1`/`scripts/destroy.sh` remove both app stacks and explicitly purge
retained DynamoDB tables, ECR repositories and Secrets Manager secrets. They
inventory exact CloudFormation IDs (including nested stacks), validate account,
region, app/stage parameters and resource identities, and require a typed
permanent-data-loss confirmation. Stack-owned S3 buckets, if added, are emptied
including versions and unfinished multipart uploads; the external templates
bucket is preserved. Deletion policies in the templates remain unchanged.
CI/CD is disabled and drained during teardown; Vercel Production is paused.
Failures retain `.setup/teardown.json` and can leave CI/CD disabled until a
successful retry. Originally enabled workflows are re-enabled after deletion.
Deploying main again builds empty AWS resources and resumes paused Vercel
Production only after its new deployment is ready. Users/data/secrets are not
restored. External bootstrap resources, detached resources/backups and Vercel
subscriptions can still incur charges.

## Phase 1 (stateful) vs Phase 2 (compute)

| Phase 1 (`DeployLambdas=false`) | Phase 2 (`DeployLambdas=true`) |
|---|---|
| ECR repository | Lambda function (ECR image) |
| DynamoDB (4 tables) | API Gateway + route |
| Cognito pool + client | domain mapping |
| IAM execution role | |
| Secrets Manager placeholder | |

## Resources per stage

| Service | Name pattern |
|---|---|
| DynamoDB | `{app}-main-{stage}`, `-ledger-`, `-throttle-`, `-webmetrics-` |
| Cognito | `{app}-pool-{stage}`, client `{app}-web-{stage}` |
| Cognito hosted domain | `{app}-{account}-{stage}` |
| ECR | `{app}-api-{stage}` |
| Lambda | `{app}-api-{stage}` (env prefix stays `SAASBASE_`) |
| API Gateway | `{app}-api-{stage}` ($default route) |
| Secrets | `{app}-app-secrets-{stage}-v4` (placeholder only) |
| SNS | `{app}-alerts-{stage}` |
| Templates bucket | `{app}-templates-{account}-{region}` |
| Root stack | `{app}-{stage}` |

## Deploy

```bash
APP_NAME=my-app bash iac/scripts/deploy-stack.sh dev 1
APP_NAME=my-app API_IMAGE_URI=<image-uri> bash iac/scripts/deploy-stack.sh dev 2
```

On the first deployment, phase 1 uses the template's `DeployLambdas=false`
default so ECR exists before the image is pushed. On subsequent deployments,
phase 1 omits `DeployLambdas` and `ApiImageUri`: AWS CLI preserves their previous
values, keeping existing compute enabled and its current image selected. It can
still update compute configuration if its templates or other parameters change.
Phase 2 requires a nonempty `API_IMAGE_URI` and enables/updates compute.
When `DEPLOY_INFRASTRUCTURE=false`, phase 2 omits all non-image parameter overrides
and skips templates-bucket creation/uploads. The checked-in root template and
previously uploaded nested templates stay unchanged for backend-only commits.
This retains CloudFormation ownership rather than updating Lambda outside IaC.

Nested-stack dependencies ensure Lambda's prerequisites finish before Lambda,
and Lambda finishes before API Gateway imports its exports. The execution role
uses Cognito's generated user pool ID; the JWKS URL derives from the exported
issuer, not the pool's display name. The Lambda log group is created before the
function, and the p99 latency alarm uses `ExtendedStatistic`.
Transactional DynamoDB writes use the existing `PutItem`, `UpdateItem`, and
`DeleteItem` IAM permissions; `TransactWriteItems` is not an IAM action.

## Validation

```bash
bash iac/tests/test-deploy-stack.sh    # mocked AWS calls; no credentials needed
bash iac/scripts/validate-templates.sh # AWS template validation; needs credentials
```

CI runs both checks before deployment. The deployment regression tests cover
first/repeat phase-one parameter handling,
phase-two image selection, app-specific naming, invalid inputs, argument quoting,
and AWS failures. CI also runs PowerShell setup/publishing tests, backend and
frontend tests, and `cfn-lint` on `iac/main.yaml` and `iac/templates/*.yaml`.
Native Git tests select one executable even when multiple Git paths are on `PATH`.
AWS `validate-template` alone does not catch all
resource-property or deployment-order errors.

The wizard renders `aws/iam.json` for the app/account/region and attaches it to
`{app}-{GitHub-repository-ID}-github-deploy`. Purge removes older app roles;
an exact-name collision appearing afterward still hard-fails setup.
GitHub assumes this role through OIDC, scoped to the
selected repository's `prod`/`dev` environments. The checked-in trust policy is
only an example; the wizard generates the actual policy, including repository
IDs discovered from GitHub.
For existing installations, `scripts/update-iam.ps1` / `scripts/update-iam.sh`
reuse setup's policy rendering, writing and sign-in helpers. The original
`.setup/state.json` must match Git origin, live repository metadata and the
role's app/repository ownership tags in the recorded AWS account. A typed
confirmation replaces only the shared dev/prod deploy inline policy; account
and immutable role identity are checked again before writing. `-Plan` performs
no IAM writes. Trust, other policies, resources and workflows are not changed.
See [IAM updates](../dev_guides/iam-issues.md#update-permissions).
Failed stack deployment prints recent root/nested failure events without
replacing the original AWS deployment exit code.

The workflow does not force-sync branches or require `PAT_PROMOTE`. It uses
single-architecture images without provenance manifests, deploys the backend
first, then builds the frontend with its API URL. PowerShell generates Vercel
Build Output API v3 artifacts with matching CSP headers and SPA routing. Only
public build artifacts are uploaded. Vercel Git integration is intentionally
not connected. Both stages share a project; main has the public Production URL
and dev has a stable Preview alias associated only with the dev branch.
Previews require Vercel authentication. GitHub's dev environment holds an
automation bypass secret used only for website verification. Main must deploy
successfully before the first Preview upload; the pipelines themselves start in parallel.

Existing installations: this changes the templates bucket naming, Cognito hosted
domain naming and pipeline configuration. It is not an automatic migration of an
existing account-specific deployment. Keep the app prefix unchanged, back up
data, and inspect changes before using this onboarding flow with existing stacks.
