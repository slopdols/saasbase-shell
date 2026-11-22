# IAM Troubleshooting

When the deploy role gets `AccessDenied`, check:

1. The OIDC trust policy matches the repository's `environment:prod` or
   `environment:dev` subject, not a branch-only subject. The setup wizard supports
   both conventional and ID-based repository subject formats.
2. The rendered `aws/iam.json` policy includes the failing action/resource.
   Updating this source does not automatically update an existing deployment
   role. Do not rerun setup: existing application names intentionally fail.
3. `iam:PassRole` allows passing the `{app}-lambda-*` execution role.
4. AWS account ID used in ECR login matches the deploy role's account.
5. `aws cloudformation deploy` works via change sets, so the role also needs
   `cloudformation:CreateChangeSet`, `DescribeChangeSet`, `ExecuteChangeSet`
   and `DeleteChangeSet` — not just `CreateStack`/`UpdateStack`.
6. Local setup uses an administrator's temporary credentials. GitHub uses the
   separate `{app}-{GitHub-repository-ID}-github-deploy` role; do not copy administrator access keys
   into GitHub or local setup files.

## Repair an existing app, not a new setup

1. Confirm the actual repository, AWS account/region, GitHub environment and
   `AWS_ROLE_ARN`. Do not infer the role from an app-name prefix alone.
2. Inspect the denied action and exact ARN in the failed run/CloudFormation
   events. Check organization SCPs, permission boundaries and trust as applicable;
   broadening an inline policy cannot override those restrictions.
3. Run the update script below with administrator credentials and confirm it.
   It uses setup's renderer and updates only that app's deploy inline policy.
   Do not copy the unrendered policy into a different app/account.
4. For trust repair, use `New-TrustPolicy` with the actual repository owner/name
   and numeric owner/repository IDs. It generates exact environment subjects in
   both supported formats; do not add branch/PR wildcards.
5. Rerun the existing app's GitHub workflow and verify actual deployment/live
   checks. Updating source or applying a policy is not deployment evidence.

### Update permissions

Run in the original application folder configured by setup:

```powershell
./scripts/update-iam.ps1
```

```bash
bash ./scripts/update-iam.sh
```

Accept the local AWS profile (or choose another administrator profile), then
type `UPDATE`. Missing tools and browser sign-in are handled automatically.
The ignored `.setup/state.json` supplies the app/account/region; live GitHub
metadata and AWS role ownership tags must match. The script checks the account
and immutable role ID again after confirmation.

It replaces only `{app}-deploy` on `{app}-{GitHub-repository-ID}-github-deploy`.
Both dev and Production use that role. Trust, permission boundaries, other
policies, GitHub/Vercel configuration and infrastructure are unchanged.
It does not start a deployment. Rerun the existing app workflow afterward.
Use `-Plan` to preview with no IAM writes, or `-AWSProfile name` to select
another local administrator profile. Missing state, templates, foreign roles,
identity changes and AWS errors fail explicitly; the script never creates a role.

Temporary-user tests require Cognito `AdminCreateUser`, `AdminSetUserPassword`
and `AdminDeleteUser` for the selected account/region's pools. The runner uses
only the exported environment pool and its own new user; it does not grant the
test user admin access. See [testing.md](testing.md).

HTTP API stage creation with CloudFormation tags can explicitly require
`apigateway:TagResource` on the **stage collection** ARN
`arn:aws:apigateway:REGION::/apis/API_ID/stages`, before a named stage exists.
The deploy policy grants it on `/apis/*/stages` only in the selected region.
Existing roles need this policy update before retrying a failed stage deployment.
The public API Gateway action catalog currently omits this literal action even
though runtime tag-on-create can enforce it; do not confuse that catalog
limitation with evidence that the observed permission failure is fixed.
See the [AWS re:Post reproduction](https://repost.aws/questions/QUMw9zvPe8RQ6SiE7YDEKmRQ/http-api-createstage-denies-tagresource-but-iam-access-analyzer-says-the-action-is-invalid).

Use [read-only inspection](aws-cli-resource-explorer.md) first. Never remove
the shared GitHub OIDC provider or replace scoped permissions with
AdministratorAccess as a deployment fix.
