# AKS to Azure Databricks OIDC Federation PoC

This package configures and validates passwordless access from an AKS ServiceAccount to Azure Databricks. All customer-specific values are supplied through `customer-config.yaml` or discovered from Azure and Databricks APIs.

## Authentication flow

```text
AKS ServiceAccount projected JWT
  -> POST <workspace>/oidc/v1/token
  -> Databricks OAuth token
  -> Workspace REST APIs and SQL Warehouse
```

No PAT, Databricks OAuth secret, Microsoft Entra client secret, or Kubernetes Secret is used.

## Quick start

Open PowerShell in the package directory:

```powershell
Set-Location <package-directory>
```

Review `customer-config.yaml`, then run a read-only plan:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Plan
```

Read the existing Kubernetes Job logs without changing Databricks resources:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Logs
```

Create the Databricks identity and grants, render the Kubernetes manifest, deploy the Job, and wait for completion:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Apply
```

`-Apply` changes Databricks and Kubernetes resources. `-Plan` and `-Logs` are read-only against those resources. Generated non-secret configuration is written to `generated/resolved-config.json`; redacted logs are written under `logs/`.

For another environment, copy `customer-config.example.yaml` to `customer-config.yaml` and replace every placeholder. The YAML must contain no password, PAT, OAuth token, client secret, projected JWT, or kubeconfig content.

## What Apply does

The YAML-driven entry point calls `configure-databricks.ps1` and `deploy.ps1` to:

1. Creates or reuses the Databricks service principal.
2. Assigns it to the target workspace with `USER`.
3. Creates or validates the AKS OIDC federation policy.
4. Grants SQL Warehouse `CAN_USE`.
5. Creates or reuses the schema.
6. Grants `USE_CATALOG` and `USE_SCHEMA`.
7. Starts the SQL Warehouse, creates the test table, initializes its row, and grants `SELECT`.
8. Validates the assignment, policy, permissions, grants, and test-table result.

Prerequisites for execution:

- `AccountProfile` is authenticated as a Databricks Account Admin.
- The current Azure CLI user can administer the target Databricks workspace; workspace operations use `azure-cli` authentication.
- `Catalog` already exists and supports managed tables.
- The AKS OIDC discovery endpoint and JWKS are publicly reachable by Databricks.
- Use a unique service principal and policy ID for a distinct workload identity.

## Expected output

```text
projected_jwt: issuer, audience, subject, and expiry summary
databricks_oauth: Bearer, all-apis, and expires_in summary
workspace_apis: service principal and visible resources
sql_warehouse: service principal identity and the configured test row
```

Raw Kubernetes JWT and Databricks OAuth token values must never appear in logs.

## Local tests

```powershell
python -m unittest -v .\test_app.py
```

## Files

- `CUSTOMER-QUICK-START.md`: English customer Quick Start and complete YAML field reference.
- `APP-PY-FLOW.html`: self-contained visual explanation of the `app.py` runtime flow and function logic.
- `customer-config.yaml`: current non-secret environment configuration.
- `customer-config.example.yaml`: reusable customer template.
- `run.ps1`: YAML validation, discovery, Plan, Apply, and Logs entry point.
- `app.py`: JWT validation, RFC 8693 token exchange, REST API checks, SQL query.
- `deployment.template.yaml`: environment-neutral ServiceAccount and Job template.
- `configure-databricks.ps1`: Databricks service principal, assignment, policy, and grants.
- `deploy.ps1`: parameterized manifest rendering, deployment, wait, and redacted logs.
- `requirements.txt`: Python runtime dependencies.
- `test_app.py`: token exchange and input validation tests.

## Sources

"Azure Databricks supports OAuth 2.0 Token Exchange [...] to let you exchange a federated identity token for a Databricks OAuth token."
Source: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-exchange

"Workload identity federation allows your automated workloads running outside of Azure Databricks to access Azure Databricks APIs without the need for Azure Databricks secrets."
Source: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-policy

- https://learn.microsoft.com/azure/aks/use-oidc-issuer
- https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-policy
- https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-exchange

KQL: N/A. This package configures and tests an authentication flow; no service telemetry was queried.