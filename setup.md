# Put your shell online

## Create your accounts (once)

### GitHub

1. [Create an account](https://github.com/signup) or sign in.
2. Use the account that should own the new private application repository.
   Your plan must support Actions and environments in private repositories.

Do not create the application repo yourself: setup creates it.

### AWS

1. [Create an AWS account](https://aws.amazon.com) and finish activation.
2. Open the [AWS console](https://console.aws.amazon.com).
   Account menu > **Security credentials** > enable root MFA.
3. **Billing and Cost Management > Budgets > Create budget**: set a monthly
   alert. Alerts do not cap spending.
4. **IAM > Users > Create user**: create a dedicated setup administrator.
   Enable **Provide user access to the AWS Management Console** and select
   **I want to create an IAM user**.
5. **Permissions options > Attach policies directly**: attach
   **AdministratorAccess** and **SignInLocalDevelopmentAccess**.
   Finish creation and securely keep the console sign-in details.
6. User > **Security credentials > Assign MFA device**: enable MFA.
   Sign out of root and sign in as this administrator.

An organization can instead provide an approved administrator role through
IAM Identity Center. Keep its **AWS access portal URL** and **SSO region**
for setup's prompts. Do not create permanent AWS access keys.

**Both AWS environments cost money.**

### Vercel

1. [Create an account](https://vercel.com/signup) and a team/workspace.
2. Open [Account Settings > Tokens](https://vercel.com/account/settings/tokens).
3. Create a `shell-setup` token scoped to that team, with permission to create
   projects and automation bypasses. Choose an expiration you can maintain.
4. Copy it into setup's hidden prompt. Accept **Save token** to reuse it from
   an encrypted, password-protected local vault.

Do not import the repo into Vercel yourself.

## Run setup

From your already-cloned shell folder:

| Platform | Command |
|---|---|
| Windows PowerShell | `./setup.ps1` |
| macOS / Ubuntu / Debian | `bash ./setup.sh` |

All tracked `.sh` scripts are executable in fresh Linux/macOS Git clones;
`./setup.sh` and `./scripts/test.sh` work directly without `chmod`. Using `bash`
as shown also works.

Follow the prompts for the app name, browser sign-in, AWS region/profile,
Vercel team/token and `SETUP` confirmation. Missing tools are installed
automatically; installers may ask for administrator/sudo permission.

Choose an unused app name: 3-24 lowercase letters, digits or hyphens.
Any existing GitHub/AWS/Vercel application-name collision stops setup.
Commit or stash local changes before running it.

Setup creates your repo, switches this folder's Git remote, runs the test
pipeline and deploys main and dev. Wait for success and use the printed app
URLs. Keep VS Code open; rename the local folder afterward if you want.
Initial branches use `[skip ci]`; setup then starts one CI/CD run per environment.
Both pipelines run in parallel; setup waits for both. The first Preview upload
waits for Production's website to be ready. API configuration is automatic.

Then open [run-this-prompt-after-setup.md](context/onboarding/run-this-prompt-after-setup.md),
describe your app and paste the prompt into your preferred AI agent.

## Scripts

Run from the application folder; add `-Plan` to destruction commands to inspect
without deleting. Account/region/team details are prompted when needed.
Purge reuses setup's saved Vercel token and recorded workspace. Without a recorded
workspace, it discovers teams using the token (choose a name/number if several).
The team ID (`team_...`) identifies your workspace, not a project. Already-deleted
repos/projects are verified as absent; no replacement project or dummy ID is needed.

| Purpose | Windows | macOS / Linux |
|---|---|---|
| Run all local tests | `./scripts/test.ps1` | `bash ./scripts/test.sh` |
| Update this app's deployment IAM permissions | `./scripts/update-iam.ps1` | `bash ./scripts/update-iam.sh` |
| Delete app AWS stacks; keep repo and pause Vercel | `./scripts/destroy.ps1` | `bash ./scripts/destroy.sh` |
| Purge repo, Vercel projects and app AWS resources/orphans | `./scripts/purge.ps1 -AppName my-app` | `bash ./scripts/purge.sh -AppName my-app` |

For IAM updates, use the original setup folder, accept your AWS profile and type
`UPDATE`. This applies the current policy to the existing app role; then rerun
the failed Actions workflow. Add `-Plan` to preview without changing permissions.

**Destroy and purge permanently delete app data, users, files and secrets.
No backups. No going back.** Review the inventory and typed confirmation.
Local files and unrelated/shared resources remain. Purge targets the selected
AWS region and Vercel team; IAM roles are account-global.

Purge requires existing AWS/GitHub sign-in and repository deletion permission:
`gh auth refresh -h github.com -s delete_repo`.
If GitHub deletion returns 403, run that command and retry the same purge.
Keep the local purge record; already-deleted AWS/Vercel resources stay deleted.
Environment-supplied tokens need their own deletion permission; refreshing CLI
sign-in does not replace them.
Purge tries independent confirmed deletions even after a failure, then lists
what remains. Retry the same command with the local purge records intact.
Ownership checks and active deployments still block unsafe deletion.

For tests, Production opt-in, token renewal and deployment failures, see
[README.md](README.md).
