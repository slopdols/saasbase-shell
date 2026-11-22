# Developer Guides

Read [AGENTS.md](../../AGENTS.md) first and [README.md](../../README.md) for the
shell's capabilities, local development, deployment and operations.

| Guide | Use it for |
|---|---|
| [coding-rules.md](coding-rules.md) | Mandatory implementation rules and feature acceptance |
| [testing.md](testing.md) | Suite ownership, fixtures, commands, real vs mocked checks and test failures |
| [saas-techstack-guide.md](saas-techstack-guide.md) | Architecture, storage and extension patterns; optional alternatives are not approved changes |
| [ci-cd-issues.md](ci-cd-issues.md) | Setup targeting, pipeline failures, Vercel protection and deployment verification |
| [iam-issues.md](iam-issues.md) | OIDC trust, deployment permissions and repair of an existing application's role |
| [aws-cli-resource-explorer.md](aws-cli-resource-explorer.md) | Read-only inspection of the selected app/account/region |
| [aws-admin-cloudshell.md](aws-admin-cloudshell.md) | Administrator operating boundaries and approved recovery, not a second setup wizard |

## Where feature documentation belongs

- **Here:** developer procedures, configuration, test conventions and technical
  decisions that affect how contributors work.
- [business_logic](../business_logic/): intended product behavior, roles, rules,
  entities and observable acceptance criteria.
- [repos](../repos/): current component structure, responsibilities, runtime and
  integration boundaries. Update orientation when the nature of a component changes.
- [plans](../plans/): proposals, approved implementation order and pending work.
- [onboarding](../onboarding/): initial product handoff and requirements workflow.

Use subfolders when useful, at the agent's discretion. Update the relevant index
and cross-links; reuse existing content instead of writing competing documents.
A feature spanning business and technical concerns needs links to both.
Keep proposals distinguishable from implemented behavior and never store secrets.

Local development is already documented in the root README; do not create a
second divergent runbook. Add a specialized guide when a new feature introduces
a developer workflow not covered by the existing ones.
