# Debugging CI/CD Pipeline Failures

Use [ci-cd-issues.md](ci-cd-issues.md) for known symptoms and [testing.md](testing.md)
for suite ownership and local commands. This guide covers inspecting an Actions
run with the `gh` CLI, interpreting skips, correlating Lambda logs and reporting
a result. Read [coding-rules.md](coding-rules.md) first.

## Confirm CLI access before diagnosing

```sh
gh --version
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef
```

The session needs a logged-in `gh` account for this repository with the `repo`
scope (read runs, jobs and logs) and the `workflow` scope (dispatch or rerun
workflows). A missing scope or an unauthenticated CLI is not a reason to request
a token in chat. Ask the owner to authorize the CLI session with
`gh auth login` or `gh auth refresh -s repo,workflow`, then continue;
never paste credentials, reuse a token from logs or switch to unauthenticated API
calls. Commands use the current git remote; add `--repo <owner>/<name>` only when
running outside the checkout.

## Find the run for the pushed commit

```sh
git rev-parse HEAD
gh run list --branch main --limit 10
gh run list --branch dev --commit "$(git rev-parse HEAD)"
gh run list --branch dev --json databaseId,headSha,status,conclusion,createdAt,url
gh run view <run-id> --json databaseId,workflowName,event,status,conclusion,headBranch,headSha,url,createdAt
```

A push to `main` deploys Production, a push to `dev` deploys the dev environment
and PRs only test. More than one run may exist for a branch; select the one whose
`headSha` matches the commit and whose `createdAt` follows the push. A commit
whose message contains `[skip ci]` creates no run at all; setup deliberately seeds
both branches this way, so a missing run is not a failure.

## Inspect jobs, steps and logs

```sh
gh run view <run-id>
gh run view <run-id> --json jobs --jq '.jobs[] | {name, status, conclusion, databaseId}'
gh run view <run-id> --log-failed
gh run view --job <job-id> --log
gh run view --job <job-id> --log-failed
gh run view <run-id> --log > /tmp/run-<run-id>.log
gh run watch <run-id> --exit-status
```

The workflow jobs are **Check changes and overrides**, `test-infrastructure`,
`test-backend`, `test-website`, `deploy`, and **Test deployed website and API**.
Use `--log-failed` first, then read the whole job log when the cause may have
happened in an earlier step (dependency install, deployment plan, image build).
Keep downloaded logs outside the repository; never commit them.

## Interpret skip annotations and skipped jobs

The plan step prints annotations and writes a `## Changes and overrides` summary.
A disabled suite appears as:

```text
::warning::SKIP_TEST_BACKEND enabled: this suite is skipped, not verified.
```

and a job gated by that output reports `skipped`. Interpret each case explicitly:

- `skipped` on a test job: the override flag disabled it. It is a warning, not a
  passing suite.
- `skipped` on `deploy`: the event was a PR, the plan selected no deployable
  component, or a deployment flag was disabled. Offline checks may still be green.
- `skipped` on **Test deployed website and API**: deployment did not succeed, the
  plan disabled post-deploy tests, or authenticated checks are not opted in on
  Production.
- `::error::` in **Check changes and overrides** (for example an unsupported or
  duplicate `config/override.env` entry) fails the plan before any test runs.
- `::error::Missing <NAME>` from **Check setup configuration** means the selected
  GitHub environment lacks a variable or secret; it is not a code failure.
- A run with a green badge but skipped deployment/live jobs is not deployment or
  live-verification evidence. Report those jobs as unverified.

## Correlate the Actions failure with AWS and Lambda logs

The Actions log shows the external symptom, while the Python traceback is in
CloudWatch. The API logs to `/aws/lambda/<APP_NAME>-api-<STAGE>` (14-day
retention), where `STAGE` is `prod` for `main` and `dev` for `dev`. Resolve
`APP_NAME`, `AWS_REGION` and the account from the selected GitHub environment or
the setup output; do not guess or cross accounts.

```sh
aws sts get-caller-identity --query Account --output text
aws logs tail "/aws/lambda/$APP_NAME-api-$STAGE" --since 30m --follow --region "$AWS_REGION"
aws logs filter-log-events \
  --log-group-name "/aws/lambda/$APP_NAME-api-$STAGE" \
  --region "$AWS_REGION" --start-time <epoch-ms> \
  --filter-pattern '"ERROR"' --output text
```

Match the request method/path and timestamp in the failing step with the
`unhandled error on <METHOD> <path>` entry, then read the following traceback.
Read-only AWS inspection follows
[aws-cli-resource-explorer.md](aws-cli-resource-explorer.md); do not modify
resources while diagnosing. If the CLI lacks credentials for the app account,
ask the owner to run the read or authorize access instead of trying another
account.

## Rerun authorization

Reading runs and logs is always allowed. Re-executing workflow runs is a
deployment action:

- `gh run rerun <run-id>` and `gh run rerun <run-id> --failed` rerun jobs on the
  original branch, including deployment and live checks. Obtain explicit owner
  authorization first.
- `gh workflow run ci-cd.yml --ref dev` dispatches a new deployment; confirm the
  branch, environment, committed configuration and authorization first.
- `gh run cancel <run-id>` can interrupt a deployment; use it only with
  authorization.
- Identify and fix the cause before rerunning. Never rerun repeatedly to hide a
  flake; a failure on the retry is a defect to reproduce locally.
- Never change secrets, environment variables, IAM policies or skip flags just to
  obtain a green run. IAM repair needs approval and the existing-role procedure in
  [iam-issues.md](iam-issues.md); enabled skips must be reported as unverified.
- Verify the new attempt with `gh run view <run-id> --attempt <n>`; do not assume
  the rerun passed.

## Failure report template

```markdown
### CI/CD failure report

- Run: <url> (`<run-id>`, attempt <n>, `<branch>@<short-sha>`)
- Plan: infrastructure=<...>; backend=<...>; website=<...>; post-deploy=<...>
- Failed job/step: <name>
- Symptom: <HTTP status, assertion or command error from the Actions log>
- Root cause: <evidence, including file:line or the exact log line>
- Correlation: log group `<...>`, window `<start-end>`, matching entry
- Fix: <code/config change or approved operational action>
- Verification: <commands and results after the fix, new run id if rerun>
- Remaining gaps: <skipped suites, mock-only checks, unavailable access>
```

Report inspected evidence, not a link or a green badge. A skipped, unavailable or
uninspected check is unverified.
