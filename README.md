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

## Prerequisites and sign-in

Open PowerShell in the project directory and install the required local tools:

```powershell
Set-Location <package-directory>
.\bootstrap.ps1
```

The bootstrap script uses WinGet to install only missing components: Azure CLI (`az`), Databricks CLI (`databricks`), Kubernetes CLI (`kubectl`), Azure Kubelogin (`kubelogin`), Python 3, and PyYAML. It does not sign in to any account or store credentials. Use `.\bootstrap.ps1 -WhatIf` to preview changes. WinGet may request administrator approval when required by a package.

The signed-in user must have:

- Azure permission to read the target AKS cluster and obtain its user credentials.
- Kubernetes RBAC permission to create, update, read, and delete the namespace, ConfigMap, ServiceAccount, and Job used by this deployment, and to read Pod logs.
- Databricks Account Admin permission for the account configured in `customer-config.yaml`.
- Databricks workspace permission to manage the selected SQL Warehouse and Unity Catalog objects.

Sign in to Azure and select the target subscription:

```powershell
az login
az account set --subscription <azure-subscription-id>
```

Sign in to the Databricks account with an Account Admin identity. The profile name must match `databricks.accountProfile` in `customer-config.yaml`:

```powershell
databricks auth login `
  --host https://accounts.azuredatabricks.net `
  --account-id <databricks-account-id> `
  --profile <databricks-account-profile>
```

After these CLI sign-ins and configuration are complete, run the scripts below. The `-Apply` workflow automatically obtains AKS credentials, configures the Databricks service principal and federation policy, applies the Kubernetes resources, waits for the test Job, and prints redacted results. No separate `az aks get-credentials`, `kubectl apply`, or manual Databricks resource setup is required.

## Quick start

Rename the example configuration file:

```powershell
Rename-Item .\customer-config.example.yaml customer-config.yaml
```

Edit `customer-config.yaml` and replace every placeholder with values for your environment. Do not add passwords, PATs, OAuth tokens, client secrets, projected JWTs, or kubeconfig content.

Then run a read-only plan to validate the configuration:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Plan
```

After reviewing the plan, create the Databricks identity and grants, render the Kubernetes manifest, deploy the Job, and wait for completion:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Apply
```

Read the deployed Kubernetes Job logs:

```powershell
.\run.ps1 -Config .\customer-config.yaml -Logs
```

`-Apply` changes Databricks and Kubernetes resources. `-Plan` and `-Logs` are read-only against those resources. Generated non-secret configuration is written to `generated/resolved-config.json`; redacted logs are written under `logs/`.

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

The selected catalog must already exist and support managed tables. The AKS OIDC discovery endpoint and JWKS must be publicly reachable by Databricks. Use a unique service principal and policy ID for each distinct workload identity.

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
- `bootstrap.ps1`: installs missing local CLI prerequisites through WinGet.
- `customer-config.example.yaml`: reusable customer template.
- `customer-config.yaml`: ignored local configuration created by renaming the example file.
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