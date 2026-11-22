# Start building your application

Setup initializes an empty app repo from the cloned shell with `[skip ci]`,
then starts main/dev pipelines in parallel and waits for both to pass.
Only the first Preview upload waits for a ready Production website.
It prints both app URLs and the Actions run links. There are two intentional
setup runs; the app has no GitHub "generated from template" metadata.
Setup rejects existing app resource names without deleting them. A separate purge
command permanently deletes an app; never run it as part of product development.
Only continue after setup reports successful deployment. Skipped deployment
steps do not prove the shell is deployed.

Replace the placeholder below, then copy the entire prompt into your preferred
AI agent with this application repository open.
Keep using your current VS Code window: setup switches Git origin without moving
the folder. Rename the local folder to your application name afterward when convenient.

---

Help me turn this deployed Saasbase shell into the following application:

**[DESCRIBE THE APP I WANT: what it does, who uses it, and anything I already know.]**

## 1. Verify the starting point

- Read `README.md`, `AGENTS.md`, `context/dev_guides/coding-rules.md`,
  `context/dev_guides/saas-techstack-guide.md`, `context/repos/backend.md`,
  `context/repos/website.md`, `context/repos/aws-infra.md`, and relevant code.
  Treat the stack guide's optional recommendations as unapproved alternatives,
  not instructions to replace the existing stack.
- Confirm Git origin and the Actions run belong to the new application
  repository, not the template. Stop if the repository identity is wrong.
- Ask me to confirm the latest main CI/CD run is fully green. Inspect that run
  if you have access: tests, backend and website deployment, health/CORS/CSP,
  and post-deployment API checks must have actually run. If you cannot inspect
  it, ask me for the run link and confirmation; do not invent a successful run.
- The shell includes native Cognito email/password registration, email-code
  verification, login and authenticated item APIs. Public smoke checks run
  after deployment; real authenticated API/browser checks run automatically on
  dev using a temporary non-admin user. Production is opt-in. Inspect the latest
  dev check results; record anything unverified, including real email delivery.
- If there is a failing baseline or code/document conflict, report it and ask
  how to proceed before treating the application as ready. Code describes
  current behavior; business documents describe intended behavior.

## 2. Understand and document the application

- Ask focused questions in small batches about users/roles, main workflows,
  data, permissions, integrations, payments if relevant, and MVP priorities.
- I may not know all the answers. Use what I can provide; clearly separate
  confirmed requirements, proposed assumptions, open questions, and deferred
  features. Do not invent answers or force decisions that can wait.
- Summarize your understanding and let me correct it.
- Update `AGENTS.md` with concise product context and links, preserving its
  engineering rules and invariants.
- Write the agreed requirements under `context/business_logic/`, following
  its existing structure: an `overall-flow.md` linking to only the relevant
  area documents. Reuse existing documents rather than duplicating them.
  Keep open questions and decisions visible. Do not put credentials here.
- Map every important feature to the right context category: product rules in
  `business_logic`, developer workflows/tests/configuration in `dev_guides`,
  changes to component nature/architecture in `repos`, and proposals in `plans`.
  Choose useful subfolders at your discretion; update indexes and cross-links
  instead of scattering unindexed files or duplicating guides.

Populate the following files, reusing existing content and creating only the
documents applicable to this app:

| File | What to write |
|---|---|
| `AGENTS.md` | Short product purpose, target users, approved MVP and links to requirements; preserve commands, implementation map and engineering rules |
| `README.md` | App description and user workflows, implemented vs planned capabilities, app-specific run/configuration/testing instructions; preserve shell operations and test policy |
| `context/business_logic/README.md` | Index of the agreed requirements and outstanding decisions |
| `context/business_logic/overall-flow.md` | Goals/non-goals, end-to-end user journeys, MVP boundaries and links to area docs |
| `context/business_logic/user-types.md` | Actors, roles, permissions, ownership/tenant boundaries and account lifecycle |
| `context/business_logic/data-models.md` | Required entities, fields/types, relationships, access patterns, validation, lifecycle and versioning; distinguish proposals from existing schema |
| Applicable area docs in `context/business_logic/` | Detailed behavior, examples and acceptance criteria for each business area; `payments.md` only if payments apply |
| `brand/branding.md` | Confirmed app naming, audience, tone and visual preferences; do not invent assets or rename technical prefixes blindly |

Keep `context/dev_guides/coding-rules.md` as the mandatory engineering contract.
Use `context/dev_guides/README.md` as the guide index and
`context/dev_guides/testing.md` for suite ownership and live-test practices.
Keep `context/dev_guides/saas-techstack-guide.md` and `context/repos/*.md` accurate
for the actual implementation; record proposed changes in plans, not as already
implemented architecture. Do not overwrite shared rules with product prose.

## 3. Ask before planning

Once the context is documented, show a concise summary and ask whether I want
an end-to-end implementation plan. **Stop until I approve planning.**

If approved, write actionable plans under `context/plans/`, following the
existing structure. Cover frontend, API contracts, authorization, data/access
patterns, infrastructure/configuration, deployment and documentation as needed.
Order dependent work explicitly, explain tradeoffs, and ask about decisions that
affect correctness, cost or architecture. Do not invent existing APIs or fields.

Each plan must include measurable acceptance criteria, required test cases,
commands to run, expected API status codes/response shapes, local verification,
deployment verification and recovery considerations. Ask for approval of the
plans and permission to implement; **do not start product implementation yet.**

Update `context/plans/README.md` with plan links and status. Use cohesive feature
plans in `context/plans/` rather than duplicating requirements. Each plan must map:

- HTTP/data behavior to `backend/api/schemas/`, `routers/`, `services/` and
  `crud/`; identify existing authorization and storage helpers to reuse.
- UI workflows to `website/src/views/`, `components/`, `stores/`, `router/`,
  `api/client.js`, `mocks/` and `i18n/locales/`.
- Infrastructure/configuration to existing `iac/`, `aws/`, `config/` and
  `setup-scripts/`, only where the feature needs changes.
- Unit/service/storage and router/API cases to `backend/tests/`; frontend unit
  cases to `website/tests/unit/`; workflow cases to `website/e2e/`; live checks
  to `website/e2e/deployed/` and `setup-scripts/test-shell.ps1`.
- Exact commands, dependent implementation order, expected outcomes and how
  changes will reach dev and, after approval, Production.

At the end, list the files populated, confirmed scope, unresolved decisions,
plan approval status and baseline verification gaps. After approval, another
agent should be able to implement a selected feature without rediscovering the
product or guessing where code/tests belong. Do not call the app implemented
or deployed merely because its documents and plans are ready.

## 4. Make testing part of every plan

- Follow the testing rules in `context/dev_guides/coding-rules.md`. Start with
  focused unit/regression tests, then local API tests against expected outputs,
  plus browser tests for the relevant workflows and authorization failures.
- Test real integration boundaries where relevant; mocks are useful but are
  not evidence of a working deployed integration. Include registration,
  verification, login and session expiry in account-related changes.
- Extend dev's default authenticated post-deployment suite for the
  product's critical workflows. It must run only after deployment finishes,
  fail CI on broken contracts, and fail explicitly if enabled credentials are
  missing. Default to dev; require explicit Production opt-in.
- Use the deployment runner's temporary least-privilege test account, not
  customer accounts. Keep credentials in memory, masked from logs, never in
  code, prompts, artifacts or frontend bundles. Create isolated test
  data and clean up only data created by that run, including on failure.
  The shell API soft-deletes items; do not claim it removes DynamoDB records.
- Production tests must not charge real money, send customer messages, change
  customer records or exercise destructive admin actions. Require approval
  before adding any such side effects.
- Report what actually passed, what failed and what remains unverified.
  Never substitute a coverage percentage or a "99% certain" claim for evidence.
- Every feature must include unit, integration/API and browser coverage for its
  applicable layers. Keep tests in the structured folders described in README.md,
  wire new suites into CI and `scripts/test.ps1`/`scripts/test.sh`, and run all
  suites before handoff.