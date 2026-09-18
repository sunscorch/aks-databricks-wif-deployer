param(
    [Parameter(Mandatory = $true)]
    [string]$DatabricksClientId,
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,
    [Parameter(Mandatory = $true)]
    [string]$KubeconfigPath,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceHost,
    [Parameter(Mandatory = $true)]
    [string]$WarehouseHttpPath,
    [Parameter(Mandatory = $true)]
    [string]$Catalog,
    [Parameter(Mandatory = $true)]
    [string]$Schema,
    [Parameter(Mandatory = $true)]
    [string]$Table,
    [Parameter(Mandatory = $true)]
    [string]$OidcAudience,
    [Parameter(Mandatory = $true)]
    [string]$OidcSubject,
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountName,
    [Parameter(Mandatory = $true)]
    [string]$JobName,
    [Parameter(Mandatory = $true)]
    [string]$ConfigMapName,
    [Parameter(Mandatory = $true)]
    [string]$ApplicationImage,
    [Parameter(Mandatory = $true)]
    [ValidateRange(600, 86400)]
    [int]$TokenExpirationSeconds,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+[smh]$')]
    [string]$JobTimeout
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppFile = "app.py=$(Join-Path $Root 'app.py')"
$RequirementsFile = "requirements.txt=$(Join-Path $Root 'requirements.txt')"
$RenderedManifestPath = Join-Path $Root "generated\deployment.yaml"

function Assert-KubernetesName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ($Name -notmatch '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$' -or $Name.Length -gt 63) {
        throw "$Field must be a valid Kubernetes DNS label of at most 63 characters."
    }
}

function ConvertTo-YamlString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return $Value | ConvertTo-Json -Compress
}

function Assert-NativeSuccess {
    param([Parameter(Mandatory = $true)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

Assert-KubernetesName -Name $Namespace -Field "Namespace"
Assert-KubernetesName -Name $ServiceAccountName -Field "ServiceAccountName"
Assert-KubernetesName -Name $JobName -Field "JobName"
Assert-KubernetesName -Name $ConfigMapName -Field "ConfigMapName"
if ($WarehouseHttpPath -notmatch '^/sql/1\.0/warehouses/[A-Za-z0-9]+$') {
    throw "WarehouseHttpPath must match /sql/1.0/warehouses/<warehouse-id>."
}
$workspaceUri = [uri]$WorkspaceHost
if ($workspaceUri.Scheme -ne "https") {
    throw "WorkspaceHost must use HTTPS."
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $KubeconfigPath) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $RenderedManifestPath) | Out-Null
az aks get-credentials `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --file $KubeconfigPath `
    --overwrite-existing | Out-Null
Assert-NativeSuccess -Operation "Get AKS credentials"

kubectl --kubeconfig $KubeconfigPath create namespace $Namespace `
    --dry-run=client --output yaml |
    kubectl --kubeconfig $KubeconfigPath apply -f -
Assert-NativeSuccess -Operation "Apply namespace"

kubectl --kubeconfig $KubeconfigPath --namespace $Namespace `
    create configmap $ConfigMapName `
    --from-file=$AppFile `
    --from-file=$RequirementsFile `
    --dry-run=client --output yaml |
    kubectl --kubeconfig $KubeconfigPath apply -f -
Assert-NativeSuccess -Operation "Apply application ConfigMap"

$manifest = Get-Content (Join-Path $Root "deployment.template.yaml") -Raw
$replacements = [ordered]@{
    "__NAMESPACE__" = $Namespace
    "__SERVICE_ACCOUNT__" = $ServiceAccountName
    "__JOB_NAME__" = $JobName
    "__CONFIG_MAP__" = $ConfigMapName
    "__APPLICATION_IMAGE__" = ConvertTo-YamlString -Value $ApplicationImage
    "__DATABRICKS_HOST__" = ConvertTo-YamlString -Value $WorkspaceHost
    "__DATABRICKS_CLIENT_ID__" = ConvertTo-YamlString -Value $DatabricksClientId
    "__EXPECTED_OIDC_AUDIENCE__" = ConvertTo-YamlString -Value $OidcAudience
    "__EXPECTED_OIDC_SUBJECT__" = ConvertTo-YamlString -Value $OidcSubject
    "__DATABRICKS_SERVER_HOSTNAME__" = ConvertTo-YamlString -Value $workspaceUri.Host
    "__DATABRICKS_HTTP_PATH__" = ConvertTo-YamlString -Value $WarehouseHttpPath
    "__DATABRICKS_CATALOG__" = ConvertTo-YamlString -Value $Catalog
    "__DATABRICKS_SCHEMA__" = ConvertTo-YamlString -Value $Schema
    "__DATABRICKS_TABLE__" = ConvertTo-YamlString -Value $Table
    "__TOKEN_EXPIRATION_SECONDS__" = [string]$TokenExpirationSeconds
}
foreach ($entry in $replacements.GetEnumerator()) {
    $manifest = $manifest.Replace($entry.Key, $entry.Value)
}
if ($manifest -match '__[A-Z0-9_]+__') {
    throw "Rendered manifest contains unresolved placeholders."
}
$manifest | Set-Content -LiteralPath $RenderedManifestPath -Encoding utf8

kubectl --kubeconfig $KubeconfigPath --namespace $Namespace `
    delete job $JobName --ignore-not-found
Assert-NativeSuccess -Operation "Delete previous test Job"
kubectl --kubeconfig $KubeconfigPath apply -f $RenderedManifestPath
Assert-NativeSuccess -Operation "Apply rendered deployment"

kubectl --kubeconfig $KubeconfigPath --namespace $Namespace `
    wait --for=condition=complete "job/$JobName" "--timeout=$JobTimeout"
Assert-NativeSuccess -Operation "Wait for test Job"
$rawLogs = @(
    kubectl --kubeconfig $KubeconfigPath --namespace $Namespace `
        logs "job/$JobName" 2>&1
)
Assert-NativeSuccess -Operation "Read test Job logs"
$redactedLogs = ($rawLogs -join [Environment]::NewLine)
$redactedLogs = $redactedLogs -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1[REDACTED]'
$redactedLogs = $redactedLogs -replace '(?i)("?(?:access_token|subject_token|id_token)"?\s*[:=]\s*"?)[^"\s,}]+', '$1[REDACTED]'
$redactedLogs = $redactedLogs -replace 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', '[REDACTED_JWT]'
Write-Output $redactedLogs