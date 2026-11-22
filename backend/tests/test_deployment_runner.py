import importlib.util
import subprocess
from pathlib import Path
from unittest.mock import Mock

import pytest

spec = importlib.util.spec_from_file_location(
    "deployment_runner",
    Path(__file__).resolve().parents[2] / "setup-scripts" / "test-deployment.py",
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@pytest.fixture
def environment():
    return {
        "STAGE": "dev",
        "AWS_REGION": "us-east-2",
        "API_URL": "https://api.example.com",
        "WEBSITE_URL": "https://app.vercel.app",
        "VERCEL_AUTOMATION_BYPASS_SECRET": "bypass",
        "VUE_APP_COGNITO_ISSUER": "https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test",
        "VUE_APP_COGNITO_CLIENT_ID": "client123",
        "AWS_SECRET_ACCESS_KEY": "bootstrap-secret",
    }


def cognito():
    client = Mock()
    client.admin_create_user.return_value = {"User": {"Username": "new-test-user"}}
    return client


@pytest.mark.parametrize(
    "stage,enabled,expected", [("dev", "false", True), ("prod", "", False), ("prod", "true", True)]
)
def test_live_checks_default_to_dev_and_require_prod_opt_in(
    monkeypatch, environment, stage, enabled, expected
):
    environment.update(STAGE=stage, RUN_AUTH_SMOKE_TESTS=enabled)
    client = cognito()
    captured = []
    monkeypatch.setattr(runner, "run_checks", lambda env: captured.append(env.copy()))
    runner.test_deployment(environment, client)
    assert captured[0]["RUN_AUTH_SMOKE_TESTS"] == str(expected).lower()
    assert "AWS_SECRET_ACCESS_KEY" not in captured[0]
    if expected:
        request = client.admin_create_user.call_args.kwargs
        assert request["MessageAction"] == "SUPPRESS"
        assert request["Username"].startswith("shell-test-")
        assert request["Username"].endswith("@example.invalid")
        assert captured[0]["SMOKE_TEST_USERNAME"] == request["Username"]
        assert "Password" not in request
        client.admin_delete_user.assert_called_once_with(
            UserPoolId="us-east-2_test", Username="new-test-user"
        )
    else:
        client.admin_create_user.assert_not_called()
        assert "VERCEL_AUTOMATION_BYPASS_SECRET" not in captured[0]


@pytest.mark.parametrize("failure", ["password", "tests"])
def test_temporary_user_is_deleted_when_configuration_or_checks_fail(
    monkeypatch, environment, failure
):
    client = cognito()
    if failure == "password":
        client.admin_set_user_password.side_effect = RuntimeError("password setup failed")
    else:
        monkeypatch.setattr(runner, "run_checks", Mock(side_effect=RuntimeError("tests failed")))
    with pytest.raises(RuntimeError):
        runner.test_deployment(environment, client)
    client.admin_delete_user.assert_called_once_with(
        UserPoolId="us-east-2_test", Username="new-test-user"
    )


def test_cleanup_failure_is_not_reported_as_success(monkeypatch, environment):
    client = cognito()
    client.admin_delete_user.side_effect = RuntimeError("cleanup failed")
    monkeypatch.setattr(runner, "run_checks", Mock())
    with pytest.raises(RuntimeError, match="cleanup failed"):
        runner.test_deployment(environment, client)


@pytest.mark.parametrize(
    "field,value",
    [
        ("STAGE", "other"),
        ("RUN_AUTH_SMOKE_TESTS", "yes"),
        ("VUE_APP_COGNITO_ISSUER", "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_other"),
        ("VERCEL_AUTOMATION_BYPASS_SECRET", ""),
    ],
)
def test_invalid_deployment_identity_fails_before_user_creation(environment, field, value):
    environment[field] = value
    client = cognito()
    with pytest.raises(ValueError):
        runner.test_deployment(environment, client)
    client.admin_create_user.assert_not_called()


def test_run_checks_executes_api_and_browser_tests_without_credentials_in_arguments(
    monkeypatch, environment
):
    monkeypatch.setattr(runner.shutil, "which", lambda name: name)
    run = Mock()
    monkeypatch.setattr(runner.subprocess, "run", run)
    environment.update(RUN_AUTH_SMOKE_TESTS="true", SMOKE_TEST_PASSWORD="secret-not-an-argument")
    runner.run_checks(environment)
    assert run.call_args_list[0].args[0][-1] == "-Authenticated"
    assert run.call_args_list[1].args[0] == ["npm", "run", "test:e2e:deployed"]
    assert all("secret-not-an-argument" not in call.args[0] for call in run.call_args_list)
    run.side_effect = subprocess.CalledProcessError(1, "pwsh")
    with pytest.raises(subprocess.CalledProcessError):
        runner.run_checks(environment)
