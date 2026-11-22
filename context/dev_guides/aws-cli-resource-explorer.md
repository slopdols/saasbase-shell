# AWS CLI Resource Explorer

Read-only inspection for an already configured application. Use the selected
AWS account/region and actual app name, not the template's `saasbase` prefix.
These commands do not provision, repair or delete resources.

In Bash/CloudShell, replace the example app/region; choose `dev` or `prod`:

```bash
export APP_NAME="my-app"
export STAGE="dev"
export AWS_REGION="us-east-2"
export STACK="${APP_NAME}-${STAGE}"

aws sts get-caller-identity
```

Confirm the returned account before continuing. A local terminal can select its
existing signed-in profile through `AWS_PROFILE`; CloudShell normally uses its
current session. No command below guarantees that your identity is read-only.

## Stacks, nested resources and failures

```bash
aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].{Name:StackName,Status:StackStatus,Id:StackId}'
aws cloudformation list-stack-resources --stack-name "$STACK"
aws cloudformation describe-stack-events --stack-name "$STACK" --max-items 50 \
  --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
  --output table
```

For failed nested stacks, repeat inspection with the exact child stack ARN
reported by the root stack or deployment diagnostics.

## Public configuration and compute

```bash
aws cloudformation list-exports \
  --query "Exports[?starts_with(Name, '${APP_NAME}-${STAGE}-')].{Name:Name,Value:Value}"
aws lambda get-function --function-name "${APP_NAME}-api-${STAGE}" \
  --query 'Configuration.{Name:FunctionName,State:State,Update:LastUpdateStatus,Modified:LastModified}'
aws apigatewayv2 get-apis \
  --query "Items[?Name=='${APP_NAME}-api-${STAGE}'].{Name:Name,Endpoint:ApiEndpoint}"
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/${APP_NAME}-api-${STAGE}"
```

Exports include the API endpoint and Cognito identifiers; they are public
configuration, not evidence that authentication or the application works.
Logs can contain sensitive data: inspect narrowly and redact before sharing.
Do not fetch secret values, tokens or customer records as routine diagnostics.
Use [IAM troubleshooting](iam-issues.md), [CI/CD troubleshooting](ci-cd-issues.md),
[the CI/CD debugging guide](ci-cd-debugging.md) and [testing.md](testing.md) for
the next step.
