# Saasbase - Coding Rules

These 8 principles are non-negotiable. Every contribution must respect them.

1. **Simplicity** - Write the simplest code that solves the problem. No
   speculative abstractions, no premature optimization. Delete dead code.

2. **Single-Purpose Functions** - Every function does one thing. Name it for
   that one thing. No hidden side effects.

3. **Errors Propagate** - Unexpected errors bubble up to the entry point.
   Never catch-and-swallow. Catch only when you can fully handle the error.
   One error boundary at the top (`api/main.py`).

4. **No Retry Nests** - Retry logic in at most one place per outbound call.
   Always bounded. Prefer no retry.

5. **Validate at Boundaries Only** - Validate input where it enters the system
   (Pydantic schemas, route guards). Do not re-validate inside. Trust internal callers.

6. **Test-Driven** - Tests are part of implementation, not a final optional step.
   Every feature ships with unit, integration/API and browser tests at its
   applicable layers, including happy paths and relevant edge/error cases.
   Tests assert behavior, not implementation details. See the verification rules below.

7. **No Secrets in Code** - Secrets come from env / AWS Secrets Manager. Never
   committed to git. Use `.env.example` templates.

8. **Money and Time**
   - Money: integer minor units (cents) + ISO-4217 currency. **Never floats.**
   - Time: ISO-8601 UTC strings. They sort lexicographically.

## Verification requirements

Use [testing.md](testing.md) for suite ownership, fixtures, commands and live-test
isolation. Maintain important feature documentation using the
[context map](README.md#where-feature-documentation-belongs).

- Define observable acceptance criteria before implementation. Add a focused
  failing unit/regression test for new behavior or a bug, then make it pass.
  Cover meaningful failures and boundary cases; do not chase coverage numbers
  or test framework internals.
- Exercise changed APIs locally: HTTP status, response shape and values,
  validation/error envelopes, authentication, ownership/role restrictions,
  optimistic-lock conflicts, and cleanup where relevant. A process starting or
  a `/health` response alone is not proof that the feature works.
- Exercise relevant browser workflows locally, including happy paths, error
  messages and protected navigation. Preserve the shell's mock flow, but also
  test native registration, email verification, login and session refresh.
  Mocked identity-provider tests do not prove real Cognito is configured.
- During development, run focused tests for quick feedback. Before acceptance,
  run **all** unit, integration/API and local browser suites through
  `scripts/test.ps1`/`scripts/test.sh`, including build/infrastructure checks. Report exact
  commands, results and unverified integrations.
- Keep unit/API/integration tests in `backend/tests`, frontend unit tests in
  `website/tests/unit`, browser tests in `website/e2e`, deployed browser tests in
  `website/e2e/deployed`, and script tests in their existing `tests` folders.
  New suites must be wired into both the full-suite runner and CI.
- Post-deployment public checks run by default in the separate live verification
  job. Authenticated API/browser checks are required on dev when that job runs,
  and explicit opt-in on Production. User-selected CI skip flags do not replace
  full local acceptance and must be reported as unverified. Extend
  `setup-scripts/test-shell.ps1` and the deployed browser suite as features grow.
  Missing configuration, broken contracts or cleanup failures must fail CI.
- Use the deployment runner's temporary non-admin Cognito user, not customer
  accounts. Credentials remain in memory and masked logs; never pass passwords
  as process arguments or expose them in traces, files or frontend bundles.
- Isolate per-run test data and clean up only records created by that run,
  including on assertion failure. Shell item deletion is soft deletion:
  inactive DynamoDB records remain. Never alter customer data, charge real
  money or send customer messages as a test; approve any side effects first.
- Treat mocks, local tests and live deployment evidence separately. Do not
  claim deployment succeeded if steps were skipped, or promise a numeric
  reliability percentage without evidence.

## Python Conventions

| Tool | Config |
|---|---|
| Black | line-length 100, target Python 3.13 |
| Ruff | rules `E, F, I, W, UP, B`; ignore `B008` (FastAPI `Depends()`) |
| mypy | strict: `disallow_untyped_defs = true`, `no_implicit_optional = true` |
| Imports | sorted via Ruff (isort-compatible) |

## Feature delivery checklist

1. Read [README](../../README.md), the relevant [orientation](../repos/),
   [business requirements](../business_logic/) and approved [plan](../plans/).
   Identify acceptance criteria and resolve material ambiguity before coding.
2. Map the feature to existing schemas/routers/services/CRUD and frontend
   views/stores/shared client. Reuse authorization, errors and localization.
3. Add tests at each applicable layer. API-backed UI changes need both backend
   contract tests and browser workflows; frontend mocks must match the real
   contract. Explain any layer that genuinely does not apply.
4. Implement the complete vertical path, including loading/empty/error states,
   ownership restrictions, validation and version conflicts where relevant.
5. Map every important change into context: technical workflows in `dev_guides`,
   product behavior in `business_logic`, component/architecture changes in `repos`,
   and proposals in `plans`. Use useful subfolders, update indexes/cross-links and
   document implemented behavior separately from pending plans. Update API/UI
   usage and applicable mocks; do not weaken these rules.
6. Run all local suites with `./scripts/test.ps1` or `bash ./scripts/test.sh`
   from the repository root, then verify real dev checks when deployment is
   authorized. Production authenticated writes remain explicit opt-in.
7. Report commands/results, deployed environment/run when verified, and remaining
   gaps. Documentation readiness, coverage numbers and mocks are not proof of a
   completed feature or working external integration.

## Key Invariants

- The CRUD layer is the ONLY code that touches the database.
- Every entity update uses optimistic locking (`version`).
- Money is never a float; timestamps are always ISO-8601 UTC.
- Errors always reach the single error boundary.
