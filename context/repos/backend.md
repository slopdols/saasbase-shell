# Backend Orientation - saasbase

Stack: **FastAPI on AWS Lambda (container image)**, DynamoDB single-table via a
pluggable CRUD layer.

## Structure

```
backend/
+-- pyproject.toml          # Black(100), Ruff(E,F,I,W,UP,B), mypy strict, pytest
+-- requirements-dev.txt    # dev deps (pytest, moto, httpx, ruff, black, mypy)
+-- api/
    +-- main.py             # FastAPI app + error boundary + middleware + Mangum handler
    +-- config.py           # Settings(BaseSettings), prefix SAASBASE_
    +-- master.py           # business-critical defaults (generic placeholders)
    +-- auth/               # cognito.py, caller.py, deps.py, device.py, anon.py, signing.py
    +-- routers/            # thin handlers: health, auth, items
    +-- services/           # business logic (items.py)
    +-- crud/               # crud.py (public API) -> backend_flag.py -> DynamoCrud | RelationalCrud
    +-- schemas/            # Pydantic request/response models
    +-- integrations/       # email.py (SES), stripe.py (skeleton)
    +-- core/               # errors, money, time, logging, metrics, alerts
+-- tests/                  # conftest + auth/core/crud/routers/services
```

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/` | none | service info |
| GET | `/health` | none | health check |
| GET | `/v1/auth/me` | JWT | caller identity |
| GET | `/v1/auth/whoami` | optional | authenticated? |
| GET | `/v1/auth/admin/status` | JWT + admin | admin gate demo |
| POST | `/v1/items` | JWT | create item |
| GET | `/v1/items` | JWT | list own items |
| GET | `/v1/items/{id}` | JWT | get item |
| PUT | `/v1/items/{id}` | JWT | update (optimistic lock) |
| DELETE | `/v1/items/{id}` | JWT | soft delete |

### DynamoDB query pagination

Table and GSI queries follow `LastEvaluatedKey` using `ExclusiveStartKey` until
the query is exhausted, including empty pages and the DynamoDB 1 MB boundary.
The CRUD layer assembles results; services still filter soft-deleted items and
query by the caller's owner key. Errors on later pages propagate, never return
a partial success.

`GET /v1/items` remains a JSON array containing the complete matching active list.
Its existing `limit` parameter (1-500; default 100) now controls each DynamoDB
request's batch size, not the total response size. The existing optional cursor
can supply a starting key; internal CRUD tuple returns retain `None` for the
next cursor after exhaustion. No client-facing page envelope or paging UI is added.
Explicit application-level pagination can be designed later if required.

Full-list reads use memory/read capacity proportional to the matching data and
remain subject to Lambda/API response-size and timeout limits; they are not a
snapshot across pages. Large applications should introduce approved server-level
result limits/pagination rather than silently truncating results.

## Conventions

- Money = integer minor units; time = ISO-8601 UTC.
- Errors propagate to `main.py` boundary; envelope `{"error": {code, message}}`.
- DB access only through `crud.py` public API.
- DynamoDB item/key maps are encoded separately from nested `M` attributes;
  unused sparse-index keys are omitted instead of written as `NULL`. Round-trip
  and transaction tests cover the low-level client wire shape.
- CI runs pytest with `--import-mode=importlib` because router/service tests share
  file basenames. It gates deployment by default; explicit CI skip flags do not
  replace the mandatory full local acceptance run.
- The Secrets Manager ARN is configured, but runtime secret loading is not yet
  implemented. Product integrations still require implementation.
- The frontend supports native Cognito registration, verification and login;
  this API validates Cognito ID-token signatures and caller permissions.
- After deployment, `setup-scripts/test-deployment.py` orchestrates public API
  checks and live browsers in the separate **Test deployed website and API** job.
  Unless that entire job is explicitly skipped, temporary-user tests run on dev and are
  explicit opt-in on Production. `test-shell.ps1` exercises identity, non-admin authorization,
  item CRUD, validation and version conflicts, then soft-delete their own item.
  See [README.md](../../README.md) for isolation and Production opt-in.
  The temporary Cognito user is deleted; these tests do not remove DynamoDB records.
