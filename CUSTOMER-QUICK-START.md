# AKS to Azure Databricks Workload Identity Federation: Customer Quick Start

## Purpose

This package deploys and validates passwordless access from an Azure Kubernetes Service (AKS) workload to Azure Databricks.

The runtime authentication chain is:

```text
AKS projected ServiceAccount JWT
  -> Azure Databricks OAuth 2.0 token exchange
  -> short-lived Databricks OAuth access token
  -> Databricks REST APIs and SQL Warehouse
```

The application does not require a Databricks personal access token (PAT), a Microsoft Entra client secret, a Databricks OAuth secret, or a Kubernetes Secret.

## Package Files

| File | Purpose |
| --- | --- |
| `customer-config.yaml` | Customer-specific, non-secret deployment configuration. |
| `customer-config.example.yaml` | Reusable template for a new environment. |
| `run.ps1` | Main entry point for Plan, Apply, and Logs modes. |
| `configure-databricks.ps1` | Creates or reuses the Databricks identity, federation policy, assignment, and permissions. |
| `deploy.ps1` | Renders and deploys the Kubernetes workload. |
| `deployment.template.yaml` | Environment-neutral Kubernetes manifest template. |
| `app.py` | Runs the projected JWT validation, token exchange, API checks, and SQL test inside AKS. |
| `requirements.txt` | Python runtime dependencies installed in the Job container. |
| `generated/resolved-config.json` | Generated non-secret values discovered from Azure and Databricks. |
| `generated/deployment.yaml` | Rendered Kubernetes manifest generated during Apply. |
| `logs/` | Timestamped, redacted application logs. |

## Prerequisites

Run the package from Windows PowerShell or PowerShell 7 on a workstation that has network access to Azure, the Databricks account, the Databricks workspace, and the AKS API server.

Required tools:

- Azure CLI (`az`)
- Databricks CLI (`databricks`)
- Kubernetes CLI (`kubectl`)
- Python 3 (`python`)
- PyYAML (`python -m pip install PyYAML`)

Required permissions:

- The Azure CLI identity can read the AKS cluster and obtain cluster credentials.
- The Databricks CLI account profile is authenticated as a Databricks Account Admin.
- The Azure CLI identity can administer the target Databricks workspace.
- The operator can grant access to the selected SQL Warehouse and Unity Catalog objects.

Validate the current sessions before deployment:

```powershell
az account show
databricks auth describe --profile <account-profile>
kubectl version --client
python --version
```

> Important: `tooling.autoInstall` and `tooling.packageManager` are reserved configuration fields. The current `run.ps1` validates required commands but does not automatically install them.

## Quick Start

### 1. Open the package directory

```powershell
Set-Location <package-directory>
```

### 2. Create the customer configuration

Copy the example and edit the new file:

```powershell
Copy-Item .\customer-config.example.yaml .\customer-config.yaml
notepad .\customer-config.yaml
```

Do not place passwords, PATs, OAuth tokens, client secrets, projected JWTs, or kubeconfig data in this YAML file.

### 3. Run a read-only plan

```powershell
.\run.ps1 -Config .\customer-config.yaml -Plan
```

Plan mode:

- Validates the YAML structure and required values.
- Reads the AKS cluster, OIDC discovery document, and JWKS endpoint.
- Reads the Databricks account workspace, SQL Warehouse, and catalog.
- Resolves the workspace hostname and SQL Warehouse HTTP path.
- Writes `generated/resolved-config.json` locally.
- Does not create, update, or delete Azure, Databricks, or Kubernetes resources.

Review the displayed AKS cluster, workspace ID, Warehouse ID, table name, OIDC subject, service principal name, and federation policy ID before continuing.

### 4. Apply the deployment

```powershell
.\run.ps1 -Config .\customer-config.yaml -Apply
```

Apply mode:

1. Creates or reuses the configured Databricks service principal.
2. Assigns the service principal to the workspace with `USER` access.
3. Creates or validates the workload identity federation policy.
4. Grants `CAN_USE` on the selected SQL Warehouse.
5. Creates or reuses the configured schema.
6. Grants `USE_CATALOG`, `USE_SCHEMA`, and, when table provisioning is enabled, `SELECT`.
7. Creates the test table if it does not exist and seeds the configured row with a non-destructive `MERGE`.
8. Generates `generated/deployment.yaml`.
9. Creates or updates the Kubernetes namespace, ConfigMap, ServiceAccount, and Job.
10. Waits for the Job to complete and prints redacted logs.

Apply is idempotent for matching objects. If an existing federation policy has different issuer, audience, or subject claims, the script stops instead of replacing it silently.

### 5. Read logs again

```powershell
.\run.ps1 -Config .\customer-config.yaml -Logs
```

Logs mode reads the existing Kubernetes Job. It does not rerun the Job and does not recreate a deleted Databricks identity. It writes a redacted copy under `logs/`.

A successful result includes:

```text
projected_jwt: expected audience and subject, valid expiration
databricks_oauth: Bearer, all-apis, expires_in
workspace_apis: current identity and visible resources
sql_warehouse: current identity and configured test row
```

## Configuration Reference

### Root

| Key | Required | Meaning |
| --- | --- | --- |
| `version` | Yes | Configuration format version. The current scripts accept only `1`. |

### Tooling

| Key | Required | Meaning |
| --- | --- | --- |
| `tooling.autoInstall` | No operational effect | Reserved flag for a future tool bootstrap workflow. The current script does not install tools. |
| `tooling.packageManager` | No operational effect | Reserved package manager name, currently documented as `winget`. |

### Azure and AKS

| Key | Required | Meaning |
| --- | --- | --- |
| `azure.subscriptionId` | Yes | Azure subscription containing the AKS cluster. `run.ps1` passes this value explicitly to Azure CLI. |
| `azure.aks.resourceGroup` | Yes | Resource group containing the AKS cluster. |
| `azure.aks.name` | Yes | AKS cluster name. The cluster must be in `Succeeded` state and expose an OIDC issuer. |

The script discovers the tenant ID, AKS region, OIDC issuer, OIDC JWKS URI, and signing-key count. These values are not entered manually.

### Databricks Account and Workspace

| Key | Required | Meaning |
| --- | --- | --- |
| `databricks.accountId` | Yes | Databricks account ID that owns the target workspace. The discovered workspace account must match this value. |
| `databricks.accountProfile` | Yes | Name of the authenticated Databricks CLI profile used for account-level operations. |
| `databricks.workspaceId` | Yes | Numeric Databricks workspace ID. The script discovers the workspace deployment hostname from this ID. |

The account profile must support commands such as:

```powershell
databricks account workspaces get <workspace-id> --profile <account-profile>
```

### SQL Warehouse

Configure exactly one selector:

| Key | Required | Meaning |
| --- | --- | --- |
| `databricks.warehouse.warehouseId` | Conditional, recommended | Stable ID of the SQL Warehouse used for `CAN_USE`, SQL execution, and the runtime connection. |
| `databricks.warehouse.httpPath` | Conditional | SQL HTTP path in `/sql/1.0/warehouses/<warehouse-id>` format. The script extracts and validates the Warehouse ID. |

Do not configure both keys. The script never selects a Warehouse by display name because names can change and may not be unique.

### Unity Catalog

| Key | Required | Meaning |
| --- | --- | --- |
| `databricks.unityCatalog.catalog` | Yes | Existing Unity Catalog catalog. The script validates that it exists. |
| `databricks.unityCatalog.schema` | Yes | Schema to create or reuse. |
| `databricks.unityCatalog.table` | Yes | Delta test table to create or reuse when table provisioning is enabled. |

Catalog, schema, and table values are also passed to `app.py`. They must be simple SQL identifiers containing letters, digits, or underscores and must not begin with a digit.

### Federated Identity

| Key | Required | Meaning |
| --- | --- | --- |
| `identity.servicePrincipalName` | Yes | Display name of the Databricks service principal. Use a unique name for each workload identity. |
| `identity.federationPolicyId` | Yes | Unique federation policy ID under the service principal. |
| `identity.federationPolicyDescription` | Yes | Human-readable policy description. |
| `identity.audience` | Yes | Audience placed in the projected Kubernetes ServiceAccount JWT and required by the Databricks policy. The package uses `databricks`. |
| `identity.kubernetesNamespace` | Yes | Kubernetes namespace containing the ServiceAccount and Job. |
| `identity.kubernetesServiceAccount` | Yes | Kubernetes ServiceAccount used by the Job. |

The script derives the federation subject exactly as:

```text
system:serviceaccount:<kubernetesNamespace>:<kubernetesServiceAccount>
```

The issuer is discovered from AKS. Issuer, audience, and subject must match the federation policy exactly.

### Kubernetes Workload

| Key | Required | Meaning |
| --- | --- | --- |
| `kubernetes.jobName` | Yes | Name of the Kubernetes Job. Apply deletes the previous Job with this exact name before creating a new run. |
| `kubernetes.configMapName` | Yes | ConfigMap containing `app.py` and `requirements.txt`. |
| `kubernetes.applicationImage` | Yes | Python container image used by the Job, for example `python:3.12-slim`. The cluster must be able to pull it. |
| `kubernetes.tokenExpirationSeconds` | Yes | Requested lifetime of the projected ServiceAccount token. The deployment script accepts 600 through 86400 seconds. |
| `kubernetes.jobTimeout` | Yes | Maximum time to wait for Job completion, for example `15m`. |

The namespace, ServiceAccount, Job, and ConfigMap names must be valid Kubernetes DNS labels of at most 63 characters.

### Test Data

| Key | Required | Meaning |
| --- | --- | --- |
| `test.provisionTable` | Yes | When `true`, Apply creates or reuses the table, merges the seed row, grants `SELECT`, and verifies the result. |
| `test.seedId` | Yes | Integer key used by the seed-row `MERGE`. Existing rows with this ID are updated; unrelated rows are preserved. |
| `test.seedMessage` | Yes | Message stored in the seed row and expected in the SQL validation output. |

When `test.provisionTable` is `false`, identity, Warehouse, catalog, and schema access are configured, but table creation, seeding, table `SELECT`, and table-result validation are skipped.

### Cleanup

| Key | Current behavior | Meaning |
| --- | --- | --- |
| `cleanup.resetDatabricksIdentity` | Reserved; not executed by `run.ps1` | Intended to request deletion and recreation of the test Databricks identity. |
| `cleanup.removeKubernetesTestResources` | Reserved; not executed by `run.ps1` | Intended to request removal of test Kubernetes resources. |
| `cleanup.removeTestTable` | Reserved; not executed by `run.ps1` | Intended to request test-table deletion with separate confirmation. |

The current package intentionally does not act on these cleanup flags. Cleanup must be performed through a separately reviewed operation. Setting one of these values to `true` does not delete anything.

## Generated Values

`generated/resolved-config.json` contains only non-secret deployment information, including:

- AKS tenant, location, OIDC issuer, and JWKS URI.
- Workspace host and hostname.
- Warehouse ID and HTTP path.
- Derived Kubernetes OIDC subject.
- Service principal ID and client ID after Apply.
- Kubernetes object names and local kubeconfig path.

`generated/deployment.yaml` contains the Databricks client ID and runtime endpoints but no token or client secret. Treat it as deployment metadata and review it before sharing outside the project team.

## Security Notes

- Never add a PAT, client secret, projected JWT, OAuth access token, or kubeconfig content to the YAML.
- The projected JWT is mounted into the Pod as an ephemeral projected volume.
- `app.py` reads both JWT and OAuth token only into process memory.
- The application prints token metadata, never token values.
- `run.ps1` and `deploy.ps1` redact JWT-shaped values and common token fields from collected logs.
- The Databricks OAuth token is short-lived and requested with `scope=all-apis`.
- Unity Catalog and Warehouse permissions determine what the federated identity can access after authentication.

## Common Failures

| Symptom | Check |
| --- | --- |
| `Missing required configuration values` | Complete every required YAML field and preserve indentation. |
| `Configure exactly one ... warehouseId or httpPath` | Keep one Warehouse selector and remove the other. |
| Workspace account mismatch | Verify `accountId`, `accountProfile`, and `workspaceId` belong to the same Databricks account. |
| AKS does not expose an OIDC issuer | Enable the AKS OIDC issuer before using direct workload identity federation. |
| Federation policy exists with different claims | Use the intended namespace and ServiceAccount, or choose a different policy ID. Do not overwrite an unrelated policy. |
| SQL Warehouse permission validation failed | Confirm the operator can manage Warehouse permissions and the Warehouse ID is correct. |
| Unity Catalog grant validation failed | Confirm the operator owns or can manage the selected catalog, schema, and table. |
| Kubernetes Job timeout | Inspect `kubectl describe job`, Pod events, image-pull access, package-download access, and the redacted Job logs. |
| OAuth exchange returns HTTP 4xx | Compare the JWT issuer, audience, subject, Databricks client ID, and policy claims exactly. |

## Recommended Customer Sequence

```powershell
Set-Location <package-directory>
Copy-Item .\customer-config.example.yaml .\customer-config.yaml
notepad .\customer-config.yaml
.\run.ps1 -Config .\customer-config.yaml -Plan
.\run.ps1 -Config .\customer-config.yaml -Apply
.\run.ps1 -Config .\customer-config.yaml -Logs
```

Run Plan after every configuration change. Use Apply only after the resolved identity and target resources have been reviewed.

## Sources

- Package implementation: `run.ps1`, `configure-databricks.ps1`, `deploy.ps1`, `deployment.template.yaml`, and `app.py`.
- Azure Databricks workload identity federation: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-policy
- Azure Databricks OAuth token exchange: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-exchange
- AKS OIDC issuer: https://learn.microsoft.com/azure/aks/use-oidc-issuer

KQL: N/A. This guide documents package configuration and operation; no service telemetry was queried.
