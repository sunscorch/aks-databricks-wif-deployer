[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [switch]$Plan,
    [switch]$Apply,
    [switch]$Logs
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $value = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $value) {
            return $null
        }
        $property = $value.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }
        $value = $property.Value
    }
    return $value
}

function Import-CustomerConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $pythonCode = @"
import json
import sys
try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required. Install it with: python -m pip install PyYAML")
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    print(json.dumps(yaml.safe_load(stream)))
"@
    $json = @(& python -c $pythonCode $resolvedPath)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to parse YAML configuration '$resolvedPath'."
    }
    return ($json -join [Environment]::NewLine) | ConvertFrom-Json
}

function Assert-CustomerConfig {
    param([Parameter(Mandatory = $true)]$InputObject)

    if ((Get-ConfigValue -InputObject $InputObject -Path "version") -ne 1) {
        throw "Only customer configuration version 1 is supported."
    }

    $requiredPaths = @(
        "azure.subscriptionId",
        "azure.aks.resourceGroup",
        "azure.aks.name",
        "databricks.accountId",
        "databricks.accountProfile",
        "databricks.workspaceId",
        "databricks.unityCatalog.catalog",
        "databricks.unityCatalog.schema",
        "databricks.unityCatalog.table",
        "identity.servicePrincipalName",
        "identity.federationPolicyId",
        "identity.federationPolicyDescription",
        "identity.audience",
        "identity.kubernetesNamespace",
        "identity.kubernetesServiceAccount",
        "kubernetes.jobName",
        "kubernetes.configMapName",
        "kubernetes.applicationImage",
        "kubernetes.tokenExpirationSeconds",
        "kubernetes.jobTimeout",
        "test.provisionTable",
        "test.seedId",
        "test.seedMessage"
    )
    $missing = @($requiredPaths | Where-Object {
        $value = Get-ConfigValue -InputObject $InputObject -Path $_
        $null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))
    })
    if ($missing.Count -gt 0) {
        throw "Missing required configuration values: $($missing -join ', ')"
    }

    $warehouseId = [string](Get-ConfigValue -InputObject $InputObject -Path "databricks.warehouse.warehouseId")
    $httpPath = [string](Get-ConfigValue -InputObject $InputObject -Path "databricks.warehouse.httpPath")
    if ([bool]$warehouseId -eq [bool]$httpPath) {
        throw "Configure exactly one of databricks.warehouse.warehouseId or databricks.warehouse.httpPath."
    }

    $configJson = $InputObject | ConvertTo-Json -Depth 20 -Compress
    if ($configJson -match '(?i)"(?:password|pat|clientSecret|accessToken|oauthToken|jwt|kubeconfig)"\s*:') {
        throw "The customer YAML contains a forbidden secret-bearing key."
    }
}

function Invoke-NativeJson {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& $Command @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $text) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Resolve-DeploymentConfig {
    param([Parameter(Mandatory = $true)]$CustomerConfig)

    $subscriptionId = [string]$CustomerConfig.azure.subscriptionId
    $resourceGroup = [string]$CustomerConfig.azure.aks.resourceGroup
    $clusterName = [string]$CustomerConfig.azure.aks.name
    $accountId = [string]$CustomerConfig.databricks.accountId
    $accountProfile = [string]$CustomerConfig.databricks.accountProfile
    $workspaceId = [string]$CustomerConfig.databricks.workspaceId

    $aks = Invoke-NativeJson -Command "az" -Arguments @(
        "aks", "show",
        "--subscription", $subscriptionId,
        "--resource-group", $resourceGroup,
        "--name", $clusterName,
        "--output", "json"
    )
    if ($aks.provisioningState -ne "Succeeded") {
        throw "AKS cluster '$clusterName' is not ready. ProvisioningState=$($aks.provisioningState)"
    }
    $oidcIssuer = [string]$aks.oidcIssuerProfile.issuerUrl
    if ([string]::IsNullOrWhiteSpace($oidcIssuer)) {
        throw "AKS cluster '$clusterName' does not expose an OIDC issuer."
    }
    $discovery = Invoke-RestMethod -Uri "$($oidcIssuer.TrimEnd('/'))/.well-known/openid-configuration"
    $jwks = Invoke-RestMethod -Uri $discovery.jwks_uri
    if (@($jwks.keys).Count -eq 0) {
        throw "AKS OIDC JWKS returned no signing keys."
    }

    $workspace = Invoke-NativeJson -Command "databricks" -Arguments @(
        "account", "workspaces", "get", $workspaceId,
        "--profile", $accountProfile,
        "--output", "json"
    )
    if ([string]$workspace.account_id -ne $accountId) {
        throw "Workspace '$workspaceId' belongs to account '$($workspace.account_id)', not configured account '$accountId'."
    }
    if ($workspace.workspace_status -ne "RUNNING") {
        throw "Databricks workspace '$workspaceId' is not running. Status=$($workspace.workspace_status)"
    }
    $workspaceHostname = "$($workspace.deployment_name).azuredatabricks.net"
    $workspaceHost = "https://$workspaceHostname"

    $configuredWarehouseId = [string]$CustomerConfig.databricks.warehouse.warehouseId
    $configuredHttpPath = [string]$CustomerConfig.databricks.warehouse.httpPath
    if ($configuredHttpPath) {
        if ($configuredHttpPath -notmatch '^/sql/1\.0/warehouses/([A-Za-z0-9]+)$') {
            throw "databricks.warehouse.httpPath must match /sql/1.0/warehouses/<warehouse-id>."
        }
        $warehouseId = $Matches[1]
    } else {
        $warehouseId = $configuredWarehouseId
    }

    $previousHost = $env:DATABRICKS_HOST
    $previousAuthType = $env:DATABRICKS_AUTH_TYPE
    try {
        $env:DATABRICKS_HOST = $workspaceHost
        $env:DATABRICKS_AUTH_TYPE = "azure-cli"
        $warehouse = Invoke-NativeJson -Command "databricks" -Arguments @(
            "warehouses", "get", $warehouseId, "--output", "json"
        )
        $catalog = Invoke-NativeJson -Command "databricks" -Arguments @(
            "catalogs", "get", [string]$CustomerConfig.databricks.unityCatalog.catalog,
            "--output", "json"
        )
    } finally {
        $env:DATABRICKS_HOST = $previousHost
        $env:DATABRICKS_AUTH_TYPE = $previousAuthType
    }

    $resolvedHttpPath = [string]$warehouse.odbc_params.path
    if ($configuredHttpPath -and $configuredHttpPath -ne $resolvedHttpPath) {
        throw "Configured HTTP path does not match Warehouse '$warehouseId'. Resolved path: $resolvedHttpPath"
    }
    if ([string]$catalog.name -ne [string]$CustomerConfig.databricks.unityCatalog.catalog) {
        throw "Configured Unity Catalog was not resolved exactly."
    }

    $namespace = [string]$CustomerConfig.identity.kubernetesNamespace
    $serviceAccount = [string]$CustomerConfig.identity.kubernetesServiceAccount
    $dateDirectory = Get-Date -Format "yyyyMMdd"
    $kubeconfigPath = Join-Path ([System.IO.Path]::GetTempPath()) `
        "aks-databricks-wif-deployer\$dateDirectory\$clusterName-kubeconfig"

    return [pscustomobject][ordered]@{
        azure = [ordered]@{
            subscriptionId = $subscriptionId
            tenantId = [string]$aks.identity.tenantId
        }
        aks = [ordered]@{
            resourceGroup = $resourceGroup
            name = $clusterName
            location = [string]$aks.location
            provisioningState = [string]$aks.provisioningState
            oidcIssuer = $oidcIssuer
            jwksUri = [string]$discovery.jwks_uri
            jwksKeyCount = @($jwks.keys).Count
            kubeconfigPath = $kubeconfigPath
        }
        databricks = [ordered]@{
            accountId = $accountId
            accountProfile = $accountProfile
            workspaceId = $workspaceId
            workspaceHost = $workspaceHost
            workspaceHostname = $workspaceHostname
            warehouseId = [string]$warehouse.id
            httpPath = $resolvedHttpPath
            catalog = [string]$CustomerConfig.databricks.unityCatalog.catalog
            schema = [string]$CustomerConfig.databricks.unityCatalog.schema
            table = [string]$CustomerConfig.databricks.unityCatalog.table
        }
        identity = [ordered]@{
            servicePrincipalName = [string]$CustomerConfig.identity.servicePrincipalName
            servicePrincipalId = $null
            clientId = $null
            policyId = [string]$CustomerConfig.identity.federationPolicyId
            policyDescription = [string]$CustomerConfig.identity.federationPolicyDescription
            audience = [string]$CustomerConfig.identity.audience
            subject = "system:serviceaccount:$namespace`:$serviceAccount"
        }
        kubernetes = [ordered]@{
            namespace = $namespace
            serviceAccount = $serviceAccount
            jobName = [string]$CustomerConfig.kubernetes.jobName
            configMapName = [string]$CustomerConfig.kubernetes.configMapName
            applicationImage = [string]$CustomerConfig.kubernetes.applicationImage
            tokenExpirationSeconds = [int]$CustomerConfig.kubernetes.tokenExpirationSeconds
            jobTimeout = [string]$CustomerConfig.kubernetes.jobTimeout
        }
        test = [ordered]@{
            provisionTable = [bool]$CustomerConfig.test.provisionTable
            seedId = [int]$CustomerConfig.test.seedId
            seedMessage = [string]$CustomerConfig.test.seedMessage
        }
    }
}

function Save-ResolvedConfig {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    $generatedDirectory = Join-Path $Root "generated"
    New-Item -ItemType Directory -Force -Path $generatedDirectory | Out-Null
    $path = Join-Path $generatedDirectory "resolved-config.json"
    $ResolvedConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "Resolved configuration: $path"
}

function Show-Plan {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    Write-Host "Plan: validate and configure AKS to Databricks workload identity federation"
    Write-Host "AKS: $($ResolvedConfig.aks.name) ($($ResolvedConfig.aks.location))"
    Write-Host "Workspace: $($ResolvedConfig.databricks.workspaceId)"
    Write-Host "Warehouse: $($ResolvedConfig.databricks.warehouseId)"
    Write-Host "Table: $($ResolvedConfig.databricks.catalog).$($ResolvedConfig.databricks.schema).$($ResolvedConfig.databricks.table)"
    Write-Host "OIDC subject: $($ResolvedConfig.identity.subject)"
    Write-Host "Service principal: $($ResolvedConfig.identity.servicePrincipalName)"
    Write-Host "Federation policy: $($ResolvedConfig.identity.policyId)"
    Write-Host "No cloud or Kubernetes resources were changed."
}

function Invoke-Apply {
    param(
        [Parameter(Mandatory = $true)]$CustomerConfig,
        [Parameter(Mandatory = $true)]$ResolvedConfig
    )

    $configureParameters = @{
        AccountProfile = $ResolvedConfig.databricks.accountProfile
        WorkspaceId = $ResolvedConfig.databricks.workspaceId
        WorkspaceHost = $ResolvedConfig.databricks.workspaceHost
        WarehouseId = $ResolvedConfig.databricks.warehouseId
        Catalog = $ResolvedConfig.databricks.catalog
        Schema = $ResolvedConfig.databricks.schema
        Table = $ResolvedConfig.databricks.table
        OidcIssuer = $ResolvedConfig.aks.oidcIssuer
        OidcAudience = $ResolvedConfig.identity.audience
        KubernetesNamespace = $ResolvedConfig.kubernetes.namespace
        KubernetesServiceAccount = $ResolvedConfig.kubernetes.serviceAccount
        ServicePrincipalName = $ResolvedConfig.identity.servicePrincipalName
        PolicyId = $ResolvedConfig.identity.policyId
        PolicyDescription = $ResolvedConfig.identity.policyDescription
        SeedId = $ResolvedConfig.test.seedId
        SeedMessage = $ResolvedConfig.test.seedMessage
    }
    if (-not $ResolvedConfig.test.provisionTable) {
        $configureParameters.SkipTableProvisioning = $true
    }
    $configurationResult = & (Join-Path $Root "configure-databricks.ps1") @configureParameters
    $ResolvedConfig.identity.servicePrincipalId = [string]$configurationResult.ServicePrincipalId
    $ResolvedConfig.identity.clientId = [string]$configurationResult.DatabricksClientId
    Save-ResolvedConfig -ResolvedConfig $ResolvedConfig

    & (Join-Path $Root "deploy.ps1") `
        -DatabricksClientId $ResolvedConfig.identity.clientId `
        -SubscriptionId $ResolvedConfig.azure.subscriptionId `
        -ResourceGroup $ResolvedConfig.aks.resourceGroup `
        -ClusterName $ResolvedConfig.aks.name `
        -KubeconfigPath $ResolvedConfig.aks.kubeconfigPath `
        -WorkspaceHost $ResolvedConfig.databricks.workspaceHost `
        -WarehouseHttpPath $ResolvedConfig.databricks.httpPath `
        -Catalog $ResolvedConfig.databricks.catalog `
        -Schema $ResolvedConfig.databricks.schema `
        -Table $ResolvedConfig.databricks.table `
        -OidcAudience $ResolvedConfig.identity.audience `
        -OidcSubject $ResolvedConfig.identity.subject `
        -Namespace $ResolvedConfig.kubernetes.namespace `
        -ServiceAccountName $ResolvedConfig.kubernetes.serviceAccount `
        -JobName $ResolvedConfig.kubernetes.jobName `
        -ConfigMapName $ResolvedConfig.kubernetes.configMapName `
        -ApplicationImage $ResolvedConfig.kubernetes.applicationImage `
        -TokenExpirationSeconds $ResolvedConfig.kubernetes.tokenExpirationSeconds `
        -JobTimeout $ResolvedConfig.kubernetes.jobTimeout
}

function Get-RedactedLogs {
    param([Parameter(Mandatory = $true)]$ResolvedConfig)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResolvedConfig.aks.kubeconfigPath) | Out-Null
    & az aks get-credentials `
        --subscription $ResolvedConfig.azure.subscriptionId `
        --resource-group $ResolvedConfig.aks.resourceGroup `
        --name $ResolvedConfig.aks.name `
        --file $ResolvedConfig.aks.kubeconfigPath `
        --overwrite-existing | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to obtain AKS credentials."
    }

    $kubectlBase = @(
        "--kubeconfig", $ResolvedConfig.aks.kubeconfigPath,
        "--namespace", $ResolvedConfig.kubernetes.namespace
    )
    & kubectl @kubectlBase get job $ResolvedConfig.kubernetes.jobName
    if ($LASTEXITCODE -ne 0) {
        throw "Kubernetes Job '$($ResolvedConfig.kubernetes.jobName)' was not found."
    }
    $rawLogs = @(& kubectl @kubectlBase logs "job/$($ResolvedConfig.kubernetes.jobName)" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve logs for Job '$($ResolvedConfig.kubernetes.jobName)'."
    }

    $redacted = ($rawLogs -join [Environment]::NewLine)
    $redacted = $redacted -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1[REDACTED]'
    $redacted = $redacted -replace '(?i)("?(?:access_token|subject_token|id_token)"?\s*[:=]\s*"?)[^"\s,}]+', '$1[REDACTED]'
    $redacted = $redacted -replace 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', '[REDACTED_JWT]'

    $logsDirectory = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force -Path $logsDirectory | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logsDirectory "$($ResolvedConfig.kubernetes.jobName)-$timestamp.log"
    $redacted | Set-Content -LiteralPath $logPath -Encoding utf8
    Write-Output $redacted
    Write-Host "Redacted log file: $logPath"
}

if (-not ($Plan -or $Apply -or $Logs)) {
    throw "Select at least one mode: -Plan, -Apply, or -Logs."
}
if ($Plan -and $Apply) {
    throw "-Plan and -Apply cannot be used together."
}

Assert-Command -Name "python"
Assert-Command -Name "az"
Assert-Command -Name "databricks"
if ($Apply -or $Logs) {
    Assert-Command -Name "kubectl"
}

$customerConfig = Import-CustomerConfig -Path $Config
Assert-CustomerConfig -InputObject $customerConfig
$resolvedConfig = Resolve-DeploymentConfig -CustomerConfig $customerConfig
Save-ResolvedConfig -ResolvedConfig $resolvedConfig

if ($Plan) {
    Show-Plan -ResolvedConfig $resolvedConfig
}
if ($Apply) {
    Invoke-Apply -CustomerConfig $customerConfig -ResolvedConfig $resolvedConfig
}
if ($Logs) {
    Get-RedactedLogs -ResolvedConfig $resolvedConfig
}