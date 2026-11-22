#!/usr/bin/env bash
# Emits external resource ARNs / values as CloudFormation parameter overrides.
# Use this to wire up resources that are provisioned OUT-OF-BAND (ACM certs,
# admin sub, website URL, Stripe account, etc.).
set -euo pipefail

STAGE="${1:?usage: $0 <stage>}"

# Optional env-driven overrides, printed one per line as "Param=value".
# Populate these in CI or a secrets manager, or hardcode where appropriate.
[ -n "${ADMIN_SUB:-}" ] && echo "AdminSub=$ADMIN_SUB"
[ -n "${WEBSITE_URL:-}" ] && echo "WebsiteUrl=$WEBSITE_URL"
[ -n "${API_DOMAIN_NAME:-}" ] && echo "ApiDomainName=$API_DOMAIN_NAME"
[ -n "${API_DOMAIN_CERT_ARN:-}" ] && echo "ApiDomainCertificateArn=$API_DOMAIN_CERT_ARN"
