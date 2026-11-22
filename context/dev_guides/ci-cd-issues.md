# CI/CD Troubleshooting

Start with [setup.md](../../setup.md).

- OIDC assumption denied: the deployment job must use GitHub environment `prod`
  or `dev`. Inspect the existing app's repository/account and role trust using
  [iam-issues.md](iam-issues.md). Repair the existing role with explicit approval;
  do not rerun setup, which only accepts unused application names.
  Do not add broad wildcard subjects or print OIDC tokens while debugging.
- Missing variables/secrets: confirm they belong to the job's environment.
  Setup stores `AWS_ROLE_ARN` and `VERCEL_TOKEN` as environment secrets; account,
  region, app name, website URL and Vercel IDs are environment variables.
  Both environments use the same Vercel project ID. The dev environment also
  needs `VERCEL_AUTOMATION_BYPASS_SECRET` for protected Preview verification.
- Backend tests do not collect: use pytest's `--import-mode=importlib`; router
  and service test files share basenames.
  See [testing.md](testing.md) for all local suite commands and fixture boundaries.
- Backend endpoint exists but URL resolution fails: AWS CLI `list-exports`
  text-mode queries are evaluated per page and can mix `None` with the endpoint.
  Deployment now retrieves combined JSON once and resolves exact API/Cognito
  export names with shared validation. Use `--output json` for diagnostics;
  do not disable pagination or recreate a healthy stack to fix this parser issue.
- Tests missing/skipped: inspect **Check changes and overrides** and the committed
  `config/override.env`. Test skip flags default off; enabled ones produce warnings.
  **Test deployed website and API** runs only after deployment succeeds, unless
  `SKIP_POST_DEPLOY_TESTS=true`. A skipped job is not live verification.
- Backend-only changes skip stateful provisioning and template uploads; the
  **Update Lambda image without reprovisioning infrastructure** step keeps the
  new image in CloudFormation's parameters. Only `iac/` changes, first
  deployments or manual dispatches, and `FORCE_ALL` perform the full two-phase
  deployment.
- Full provisioning ran although only non-IaC files changed: the deployment plan
  diffs against the previous remote commit. Template-generated repositories keep
  a single root commit as their first remote commit; that commit is still diffed
  normally instead of being treated as the initial deployment. Only changes under
  `iac/` select full provisioning on ordinary pushes.
- AWS deployment failed: read the root/nested failed stack events printed by
  `iac/scripts/deploy-stack.sh`. An existing templates-bucket message alone is
  not the cause. Do not delete resources or change app prefixes as a workaround
  without approval and a reviewed inventory.
- `ApiStage` fails with `apigateway:TagResource`: update the existing deploy
  role's current rendered policy as described in [iam-issues.md](iam-issues.md).
  The grant targets regional stage-collection ARNs, not just HTTP management
  verbs. Rerun the app workflow after repair; do not rerun setup.
- Image format rejected by Lambda: publish a single Linux amd64 image, without
  a multi-platform/provenance index. The workflow disables provenance/SBOM and
  deploys the pushed image's digest.
- Backend succeeded but frontend failed: rerun the workflow after fixing the
  Vercel/build error. Phase one preserves existing compute and its image.
- Unexpected independent Vercel builds: disconnect the project's Git integration.
  The setup path uses GitHub-orchestrated prebuilt deployments, not `vercel.sh`.
- Dev waiting before upload: main/dev pipelines start in parallel, but a new
  Vercel project's first deployment can become Production regardless of the CLI
  flag. Preview waits up to 20 minutes for a ready Production website. Inspect
  main's frontend step if it times out; tests/backends/builds run independently.
- Preview asks for authentication: expected. Sign into Vercel for browser access;
  automated checks use the shared project's automation bypass secret via a
  website-only header. Never disable protection or send that header to AWS.
- Existing/partial installations: setup does not resume or migrate them.
  Preserve `.setup`, inspect the generated repo, cloud resources and environment
  settings, and plan a targeted repair. Old two-project Vercel layouts need an
  explicitly approved migration; changed website URLs require matching API CORS.
- Authenticated dev checks fail: dev always requires the exported Cognito
  configuration, current test-user IAM permissions and Vercel bypass.
  `RUN_AUTH_SMOKE_TESTS=false` cannot disable dev checks. Production remains
  explicit opt-in. Missing contracts/cleanup are failures, not warnings to skip.
- A workflow is green but did not deploy: PRs and documentation-only changes can
  legitimately skip deploy jobs. Verify selected deployment steps and real live
  checks before claiming the app was deployed.
- Extra "Initial commit" runs in an older setup came from GitHub template
  generation and creating dev at that generated commit. Current setup creates
  an empty repo and uses a CI-skipped commit for both branches, then dispatches
  exactly one main and one dev run. Existing runs are not retroactively removed.
- Interrupted destroy/purge: keep the identity journal and retry the same
  authorized operation; inspect disabled workflows and replacement-resource
  errors. Never delete a journal to bypass its protections.
- Purge hits an already-inactive workflow: current purge skips disabled states
  and rechecks a shutdown race. Other permission errors and active runs remain
  blockers before cloud deletion.
- Purge reports stack ownership failure: inspect the printed resource and stack
  IDs. Missing `RootId` on a deleted nested stack uses actual historical parent
  inventory, not a name-based guess. Unavailable/foreign ownership stays blocked.
  It does not establish that the templates bucket is the failing resource.
- A confirmed purge deletion fails: other independent resources/providers are
  still attempted. Read the final failed/unverified list, fix permissions or
  dependencies, and retry with the same journals. Already-deleted targets remain
  absent. Ordinary destroy is still fail-fast.
- No `main-passed-tests` branch or promotion PAT is needed. Push `main` and `dev`
  independently; there is no automatic force-sync.
