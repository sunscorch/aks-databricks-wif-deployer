# YAML-Driven AKS to Databricks Federation Deployer Plan

## 1. Objective

Build a reusable Windows PowerShell deployment package driven by one customer YAML file.

The package will:

1. Install or validate required local tools.
2. Validate Azure CLI and Databricks CLI authentication.
3. Discover AKS and Databricks runtime properties.
4. Generate a resolved configuration file without secrets.
5. Optionally remove an existing test federation identity after explicit confirmation.
6. Create the Databricks service principal, workspace assignment, federation policy, SQL Warehouse permission, and Unity Catalog grants.
7. Render the Kubernetes manifest from the resolved configuration.
8. Deploy `app.py` to AKS.
9. Wait for the Job and display redacted application logs.

## 2. Zero-Hardcoding Rule

No environment-specific value may be embedded in PowerShell, Python, or Kubernetes template files.

The following values must come from the customer YAML or be discovered from APIs:

- Azure subscription ID.
- AKS resource group and cluster name.
- Databricks account ID and CLI profile.
- Databricks workspace ID.
- Workspace URL and hostname.
- SQL Warehouse ID and HTTP path.
- Catalog, schema, and table.
- Databricks service principal name.
- Federation policy ID and description.
- OIDC issuer, audience, namespace, ServiceAccount, and subject.
- Kubernetes Job, ConfigMap, namespace, and ServiceAccount names.
- Container image, timeout, and token lifetime.
- Test row values and SQL behavior.

Scripts must not contain fallback production identifiers. Missing required values must cause a clear validation error.

## 3. SQL Warehouse Identification

Do not use the SQL Warehouse display name because names are mutable and may not be unique.

The YAML must provide exactly one of:

- `warehouseId`, recommended.
- `httpPath`, accepted.

Resolution rules:

1. If `warehouseId` is provided, query the workspace API to verify it and derive `httpPath`.
2. If `httpPath` is provided, validate `/sql/1.0/warehouses/<warehouse-id>` and extract the ID.
3. If both are provided, verify that they identify the same warehouse.
4. Never select a warehouse by display name.

## 4. Proposed Customer Configuration

```yaml
version: 1

tooling:
  autoInstall: true
  packageManager: winget

azure:
  subscriptionId: "<azure-subscription-id>"
  aks:
    resourceGroup: "<aks-resource-group>"
    name: "<aks-cluster-name>"

databricks:
  accountId: "<databricks-account-id>"
  accountProfile: "<databricks-cli-profile>"
  workspaceId: "<workspace-id>"

  warehouse:
    warehouseId: "<warehouse-id>"
    # httpPath: "/sql/1.0/warehouses/<warehouse-id>"

  unityCatalog:
    catalog: "<existing-managed-catalog>"
    schema: "<schema-to-create-or-reuse>"
    table: "<test-table-to-create-or-reuse>"

identity:
  servicePrincipalName: "<unique-databricks-service-principal-name>"
  federationPolicyId: "<unique-policy-id-for-this-service-principal>"
  federationPolicyDescription: "<description>"
  audience: "databricks"
  kubernetesNamespace: "<namespace>"
  kubernetesServiceAccount: "<service-account>"

kubernetes:
  jobName: "<job-name>"
  configMapName: "<configmap-name>"
  applicationImage: "<python-container-image>"
  tokenExpirationSeconds: 3600
  jobTimeout: "15m"

test:
  provisionTable: true
  seedId: 1
  seedMessage: "<test-message>"

cleanup:
  resetDatabricksIdentity: false
  removeKubernetesTestResources: false
  removeTestTable: false
```

The YAML must not contain passwords, PATs, OAuth tokens, client secrets, kubeconfig content, or projected JWTs.

## 5. Customer-Provided Values

The customer must provide:

- Azure subscription ID.
- AKS resource group and cluster name.
- Databricks account ID and authenticated profile name.
- Databricks workspace ID.
- SQL Warehouse ID or HTTP path.
- Existing managed catalog name.
- Desired schema and table names.
- Desired Databricks service principal name.
- Desired federation policy ID.
- Desired Kubernetes namespace and ServiceAccount.
- Application image and deployment object names.

## 6. Automatically Discovered Values

The discovery script will retrieve:

### Azure and AKS

- Active subscription and tenant.
- AKS region and provisioning state.
- Kubernetes version.
- API server FQDN.
- OIDC issuer URL.
- OIDC discovery document and JWKS URI.
- Node readiness through a newly generated kubeconfig.

### Databricks Account

- Workspace membership in the configured account.
- Workspace URL from the workspace ID.
- Existing service principal ID and application/client ID.
- Existing federation policy and its claims.

### Databricks Workspace

- Workspace hostname.
- SQL Warehouse details and HTTP path.
- Warehouse state and permission information.
- Catalog and schema existence.
- Existing Unity Catalog grants.

### Derived Values

- OIDC subject:
  `system:serviceaccount:<namespace>:<service-account>`
- Databricks SQL server hostname.
- Full table name.
- Kubernetes environment variables.
- Temporary kubeconfig path.

## 7. Generated Resolved Configuration

The discovery/configuration phase will write:

```text
generated/resolved-config.json
```

It will include only non-secret data:

```json
{
  "azure": {
    "subscriptionId": "...",
    "tenantId": "..."
  },
  "aks": {
    "resourceGroup": "...",
    "name": "...",
    "location": "...",
    "oidcIssuer": "...",
    "kubeconfigPath": "..."
  },
  "databricks": {
    "accountId": "...",
    "workspaceId": "...",
    "workspaceHost": "...",
    "workspaceHostname": "...",
    "warehouseId": "...",
    "httpPath": "/sql/1.0/warehouses/...",
    "catalog": "...",
    "schema": "...",
    "table": "..."
  },
  "identity": {
    "servicePrincipalName": "...",
    "servicePrincipalId": "...",
    "clientId": "...",
    "policyId": "...",
    "audience": "...",
    "subject": "system:serviceaccount:...:..."
  },
  "kubernetes": {
    "namespace": "...",
    "serviceAccount": "...",
    "jobName": "...",
    "configMapName": "..."
  }
}
```

`deploy.ps1` must read only this generated file. It must not independently invent or default any environment value.

## 8. Proposed Package Layout

```text
aks-databricks-wif-deployer/
  customer-config.example.yaml
  customer-config.yaml
  run.ps1
  bootstrap.ps1
  validate-config.ps1
  discover.ps1
  reset-identity.ps1
  configure-databricks.ps1
  render-deployment.ps1
  deploy.ps1
  get-logs.ps1
  app/
    app.py
    requirements.txt
  templates/
    deployment.yaml.tpl
  generated/
    resolved-config.json
    deployment.yaml
  logs/
  tests/
  README.md
  IMPLEMENTATION-PLAN.md
```

## 9. Tool Bootstrap

`bootstrap.ps1` detects and installs only missing tools:

- Azure CLI (`az`).
- Databricks CLI.
- `kubectl`.
- `kubelogin` when required by AKS authentication.
- Python 3 and PyYAML for structured YAML parsing.

Rules:

- Use WinGet package IDs, not arbitrary download URLs.
- Leave existing installations unchanged and install the current WinGet package when a command is missing.
- Do not silently trigger elevation.
- Stop and provide a clear message if administrator approval is required.
- Do not automate usernames, passwords, MFA, or browser credentials.
- If authentication is missing, display the exact `az login` or `databricks auth login` command and pause.

## 10. Execution Modes

### Plan Mode

```powershell
.\run.ps1 -Config .\customer-config.yaml -Plan
```

Plan mode will:

- Validate YAML syntax and required fields.
- Validate tools and login contexts.
- Discover read-only Azure, AKS, Databricks account, workspace, and warehouse data.
- Validate OIDC discovery and JWKS.
- Generate a change plan.
- Not create, update, or delete cloud or Kubernetes resources.

### Apply Mode

```powershell
.\run.ps1 -Config .\customer-config.yaml -Apply
```

Apply mode will:

- Generate `resolved-config.json`.
- Create or reuse the configured Databricks service principal.
- Assign it to the configured workspace.
- Create or validate the federation policy.
- Apply Warehouse and Unity Catalog permissions.
- Optionally provision the test table using a non-destructive `MERGE`.
- Render and deploy the Kubernetes objects.
- Wait for the Job and print redacted logs.

### Reset and Rebuild Mode

```powershell
.\run.ps1 -Config .\customer-config.yaml -ResetIdentity -Apply
```

Reset requires an additional interactive confirmation unless `-ConfirmReset` is explicitly supplied.

## 11. Safe Identity Reset

The current proof-of-concept objects are eligible for reset only after exact account, workspace, name, and policy verification.

Reset order:

1. Resolve the service principal by the YAML `servicePrincipalName`.
2. Fail if zero or multiple matches are returned.
3. Resolve the policy by the YAML `federationPolicyId` under that exact principal.
4. Display principal ID, client ID, workspace ID, policy claims, and affected grants.
5. Remove the federation policy.
6. Remove the workspace assignment.
7. Delete the Databricks service principal.
8. Verify all three objects are absent.

Commands are resolved dynamically. No existing principal or policy ID may be hardcoded into reset logic.

The reset process must not delete:

- The Databricks workspace.
- The SQL Warehouse.
- The catalog.
- The schema or table unless `cleanup.removeTestTable` is true and separately confirmed.
- The AKS cluster.

## 12. Databricks Configuration Phase

The script will perform these idempotent operations:

1. Create or reuse the configured Databricks service principal.
2. Assign `USER` on the configured workspace.
3. Create or validate the federation policy.
4. Verify policy issuer, audience, and subject exactly match the resolved AKS identity.
5. Grant `CAN_USE` on the Warehouse ID.
6. Create or reuse the schema in the configured catalog.
7. Grant `USE_CATALOG`.
8. Grant `USE_SCHEMA`.
9. Optionally create the table and use `MERGE` for the test row.
10. Grant `SELECT` on the configured table.
11. Validate every assignment and grant.

An existing policy with mismatched claims must stop execution. The script must not silently replace it.

## 13. Kubernetes Rendering and Deployment

`render-deployment.ps1` will read `resolved-config.json` and generate:

```text
generated/deployment.yaml
```

The rendered manifest will define:

- Namespace.
- ServiceAccount.
- ConfigMap containing `app.py` and `requirements.txt`.
- Job.
- Projected ServiceAccount token volume.
- Audience and token lifetime.
- Databricks host, client ID, Warehouse HTTP path, catalog, schema, and table environment variables.

The rendered ServiceAccount and policy subject must be validated as the same identity before deployment.

## 14. Application and Logs

`app.py` will:

1. Read the projected Kubernetes JWT.
2. Validate audience, subject, and expiration.
3. Exchange it at `/oidc/v1/token` using RFC 8693.
4. Call Databricks workspace APIs.
5. Connect to the configured SQL Warehouse.
6. Query the configured table.
7. Print only safe metadata and bounded test results.

`get-logs.ps1` will:

- Resolve the Job and Pod names from `resolved-config.json`.
- Display Job status, Pod state, container exit code, and application logs.
- Redact JWT-like strings and bearer/access token values.
- Save a timestamped copy under `logs/`.

## 15. Validation Strategy

Local tests:

- YAML schema validation.
- Required/exclusive field validation for Warehouse ID and HTTP path.
- PowerShell parser checks.
- Mock CLI tests for discovery and reset resolution.
- Golden-file tests for rendered Kubernetes YAML.
- Python JWT and RFC 8693 unit tests.
- Secret scanning of YAML, JSON, manifests, and logs.

Live validation:

- AKS state is `Succeeded` and nodes are Ready.
- OIDC discovery and JWKS return successfully.
- Federation policy claims match the projected JWT.
- Job completes with exit code 0.
- Databricks current identity equals the generated client ID.
- Warehouse, catalog, schema, and table are visible.
- SQL returns the configured seed row.
- No PAT, client secret, JWT, or OAuth token appears in files or logs.

## 16. Implementation Sequence

1. Create the package skeleton in Downloads.
2. Create the commented example YAML and JSON schema.
3. Implement bootstrap and authentication preflight.
4. Implement structured YAML parsing and validation.
5. Implement Azure/AKS and Databricks discovery.
6. Implement resolved config generation.
7. Implement Plan mode and change summary.
8. Implement guarded identity reset.
9. Refactor Databricks configuration to read resolved config only.
10. Refactor manifest rendering and deployment to read resolved config only.
11. Implement log retrieval and redaction.
12. Add local tests and secret scans.
13. Run Plan mode against the current environment.
14. After explicit confirmation, reset the current test identity.
15. Run Apply mode end to end and compare results with the original PoC.

## 17. Acceptance Criteria

- One customer YAML is the only environment-specific input.
- No environment identifier is hardcoded in executable files.
- Warehouse selection uses ID or HTTP path, never display name.
- Plan mode has no external side effects.
- Reset cannot delete a principal or policy that does not exactly match the YAML.
- `resolved-config.json` contains no secrets.
- Deploy reads only resolved config and generated artifacts.
- Kubernetes objects use the YAML names.
- Federation policy subject exactly matches the deployed ServiceAccount.
- End-to-end token exchange and SQL query succeed.
- Logs are available and contain no token values.

## Sources

"Workload identity federation allows your automated workloads running outside of Azure Databricks to access Azure Databricks APIs without the need for Azure Databricks secrets."
Source: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-policy

"Azure Databricks supports OAuth 2.0 Token Exchange [...] to let you exchange a federated identity token for a Databricks OAuth token."
Source: https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-exchange

- https://learn.microsoft.com/azure/aks/use-oidc-issuer
- https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-policy
- https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-federation-exchange
- https://learn.microsoft.com/azure/databricks/dev-tools/cli/reference/account-workspace-assignment-commands
- https://learn.microsoft.com/azure/databricks/data-governance/unity-catalog/access-control/privileges-reference

KQL: N/A. This is an implementation plan; no service telemetry was queried.