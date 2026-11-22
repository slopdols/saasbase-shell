"""Run deployed API/browser checks with an isolated, temporary Cognito user."""

import os
import re
import secrets
import shutil
import subprocess
from pathlib import Path
from typing import Protocol
from uuid import uuid4

import boto3

ROOT = Path(__file__).resolve().parent.parent


class CognitoClient(Protocol):
    def admin_create_user(self, **kwargs: object) -> dict[str, dict[str, str]]: ...

    def admin_set_user_password(self, **kwargs: object) -> dict[str, object]: ...

    def admin_delete_user(self, **kwargs: object) -> dict[str, object]: ...


def run_checks(environment: dict[str, str]) -> None:
    pwsh = shutil.which("pwsh")
    npm = shutil.which("npm")
    if not pwsh or not npm:
        raise RuntimeError("PowerShell and npm are required for deployment tests.")
    arguments = [
        pwsh,
        "-NoProfile",
        "-File",
        str(ROOT / "setup-scripts" / "test-shell.ps1"),
        "-ApiUrl",
        environment["API_URL"],
        "-Stage",
        environment["STAGE"],
    ]
    if environment["RUN_AUTH_SMOKE_TESTS"] == "true":
        arguments.append("-Authenticated")
    subprocess.run(arguments, check=True, env=environment, timeout=300)
    subprocess.run(
        [npm, "run", "test:e2e:deployed"],
        cwd=ROOT / "website",
        check=True,
        env=environment,
        timeout=300,
    )


def test_deployment(environment: dict[str, str], client: CognitoClient | None = None) -> None:
    stage = environment.get("STAGE", "")
    enabled = environment.get("RUN_AUTH_SMOKE_TESTS", "")
    if stage not in ("dev", "prod") or enabled not in ("", "false", "true"):
        raise ValueError("STAGE must be dev/prod and RUN_AUTH_SMOKE_TESTS must be true/false.")
    for name in ("API_URL", "WEBSITE_URL"):
        if not re.fullmatch(r"https://[a-z0-9.-]+", environment.get(name, "")):
            raise ValueError(f"{name} must be an HTTPS origin.")
    if stage == "dev" and not environment.get("VERCEL_AUTOMATION_BYPASS_SECRET"):
        raise ValueError("Dev deployment tests require the Vercel protection bypass.")
    authenticated = stage == "dev" or enabled == "true"
    child_env = environment.copy()
    child_env["RUN_AUTH_SMOKE_TESTS"] = str(authenticated).lower()
    for name in (
        "SMOKE_TEST_USERNAME",
        "SMOKE_TEST_PASSWORD",
        "VERCEL_TOKEN",
        "GITHUB_TOKEN",
        "GH_TOKEN",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
    ):
        child_env.pop(name, None)
    if not authenticated:
        child_env.pop("VERCEL_AUTOMATION_BYPASS_SECRET", None)
        run_checks(child_env)
        return
    issuer = environment.get("VUE_APP_COGNITO_ISSUER", "")
    match = re.fullmatch(
        r"https://cognito-idp\.([a-z0-9-]+)\.amazonaws\.com/([a-z0-9-]+_[a-zA-Z0-9]+)",
        issuer,
    )
    if (
        not match
        or match[1] != environment.get("AWS_REGION")
        or not match[2].startswith(f"{match[1]}_")
    ):
        raise ValueError("Cognito issuer must identify a pool in the deployment region.")
    if not environment.get("VUE_APP_COGNITO_CLIENT_ID"):
        raise ValueError("Cognito client ID is required.")
    if client is None:
        client = boto3.client("cognito-idp", region_name=match[1])
    pool_id = match[2]
    email = f"shell-test-{uuid4().hex}@example.invalid"
    password = f"Aa1!{secrets.token_hex(24)}"
    if environment.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{password}", flush=True)
        print(f"::add-mask::{email}", flush=True)
    user = client.admin_create_user(
        UserPoolId=pool_id,
        Username=email,
        UserAttributes=[
            {"Name": "email", "Value": email},
            {"Name": "email_verified", "Value": "true"},
        ],
        MessageAction="SUPPRESS",
    )["User"]["Username"]
    try:
        client.admin_set_user_password(
            UserPoolId=pool_id, Username=user, Password=password, Permanent=True
        )
        child_env["SMOKE_TEST_USERNAME"] = email
        child_env["SMOKE_TEST_PASSWORD"] = password
        run_checks(child_env)
    finally:
        child_env.pop("SMOKE_TEST_PASSWORD", None)
        child_env.pop("SMOKE_TEST_USERNAME", None)
        client.admin_delete_user(UserPoolId=pool_id, Username=user)


if __name__ == "__main__":
    test_deployment(dict(os.environ))
