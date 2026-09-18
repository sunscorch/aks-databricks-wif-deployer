param(
    [Parameter(Mandatory = $true)]
    [Alias("Profile")]
    [string]$AccountProfile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceHost,
    [Parameter(Mandatory = $true)]
    [string]$WarehouseId,
    [Parameter(Mandatory = $true)]
    [string]$Catalog,
    [Parameter(Mandatory = $true)]
    [string]$Schema,
    [Parameter(Mandatory = $true)]
    [string]$Table,
    [Parameter(Mandatory = $true)]
    [string]$OidcIssuer,
    [Parameter(Mandatory = $true)]
    [string]$OidcAudience,
    [Parameter(Mandatory = $true)]
    [string]$KubernetesNamespace,
    [Parameter(Mandatory = $true)]
    [string]$KubernetesServiceAccount,
    [Parameter(Mandatory = $true)]
    [string]$ServicePrincipalName,
    [Parameter(Mandatory = $true)]
    [string]$PolicyId,
    [Parameter(Mandatory = $true)]
    [string]$PolicyDescription,
    [Parameter(Mandatory = $true)]
    [int]$SeedId,
    [Parameter(Mandatory = $true)]
    [string]$SeedMessage,
    [switch]$SkipTableProvisioning,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"

function Invoke-DatabricksJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& databricks @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "databricks $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $text) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function ConvertTo-SqlIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return '`' + $Value.Replace('`', '``') + '`'
}

function ConvertTo-SqlString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-SqlStatement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Statement
    )

    $body = @{
        warehouse_id = $WarehouseId
        catalog = $Catalog
        schema = $Schema
        statement = $Statement
        disposition = "INLINE"
        wait_timeout = "50s"
        on_wait_timeout = "CANCEL"
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-DatabricksJson -Arguments @(
        "api", "post", "/api/2.0/sql/statements",
        "--json", $body,
        "--output", "json"
    )
    if ($response.status.state -ne "SUCCEEDED") {
        throw "SQL statement failed. State=$($response.status.state); Error=$($response.status.error.message)"
    }
    return $response
}

function Add-UnityCatalogGrant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecurableType,
        [Parameter(Mandatory = $true)]
        [string]$FullName,
        [Parameter(Mandatory = $true)]
        [string]$Privilege,
        [Parameter(Mandatory = $true)]
        [string]$Principal
    )

    $body = @{
        changes = @(
            @{
                principal = $Principal
                add = @($Privilege)
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-DatabricksJson -Arguments @(
        "grants", "update", $SecurableType, $FullName,
        "--json", $body,
        "--output", "json"
    ) | Out-Null
}

if (-not $OidcIssuer.EndsWith('/')) {
    $OidcIssuer += '/'
}
$OidcSubject = "system:serviceaccount:$KubernetesNamespace`:$KubernetesServiceAccount"
$WorkspaceHostname = ([uri]$WorkspaceHost).Host
$CatalogSql = ConvertTo-SqlIdentifier -Value $Catalog
$SchemaSql = ConvertTo-SqlIdentifier -Value $Schema
$TableSql = ConvertTo-SqlIdentifier -Value $Table
$TableFullName = "$Catalog.$Schema.$Table"

$configuration = [ordered]@{
    AccountProfile = $AccountProfile
    WorkspaceId = $WorkspaceId
    WorkspaceHost = $WorkspaceHost
    WorkspaceHostname = $WorkspaceHostname
    WarehouseId = $WarehouseId
    Catalog = $Catalog
    Schema = $Schema
    Table = $Table
    KubernetesNamespace = $KubernetesNamespace
    KubernetesServiceAccount = $KubernetesServiceAccount
    ServicePrincipalName = $ServicePrincipalName
    FederationPolicy = $PolicyId
    PolicyDescription = $PolicyDescription
    OidcIssuer = $OidcIssuer
    OidcAudience = $OidcAudience
    OidcSubject = $OidcSubject
    SeedId = $SeedId
    SeedMessage = $SeedMessage
    SkipTableProvisioning = [bool]$SkipTableProvisioning
}
if ($PlanOnly) {
    return [pscustomobject]$configuration
}

Write-Host "1/9 Create or reuse the Databricks service principal"
$principals = @(
    Invoke-DatabricksJson -Arguments @(
        "account", "service-principals", "list",
        "--filter", "displayName eq '$ServicePrincipalName'",
        "--profile", $AccountProfile,
        "--output", "json"
    )
)
if ($principals.Count -eq 0) {
    $principal = Invoke-DatabricksJson -Arguments @(
        "account", "service-principals", "create",
        "--display-name", $ServicePrincipalName,
        "--active",
        "--profile", $AccountProfile,
        "--output", "json"
    )
} elseif ($principals.Count -eq 1) {
    $principal = $principals[0]
} else {
    throw "Multiple service principals named '$ServicePrincipalName' exist. Use a unique name."
}
$principalId = [string]$principal.id
$clientId = [string]$principal.applicationId

Write-Host "2/9 Assign the service principal to workspace $WorkspaceId"
$assignments = @(
    Invoke-DatabricksJson -Arguments @(
        "account", "workspace-assignment", "list", $WorkspaceId,
        "--profile", $AccountProfile,
        "--output", "json"
    )
)
$assignment = $assignments | Where-Object {
    [string]$_.principal.principal_id -eq $principalId
}
if (-not $assignment -or $assignment.permissions -notcontains "USER") {
    Invoke-DatabricksJson -Arguments @(
        "account", "workspace-assignment", "update", $WorkspaceId, $principalId,
        "--json", '{"permissions":["USER"]}',
        "--profile", $AccountProfile,
        "--output", "json"
    ) | Out-Null
}

Write-Host "3/9 Create or validate the federation policy"
$policies = @(
    Invoke-DatabricksJson -Arguments @(
        "account", "service-principal-federation-policy", "list", $principalId,
        "--profile", $AccountProfile,
        "--output", "json"
    )
)
$policy = $policies | Where-Object { $_.policy_id -eq $PolicyId }
if ($policy) {
    if (
        $policy.oidc_policy.issuer -ne $OidcIssuer -or
        $policy.oidc_policy.subject -ne $OidcSubject -or
        @($policy.oidc_policy.audiences) -notcontains $OidcAudience
    ) {
        throw "Federation policy '$PolicyId' exists with different claims. Use another PolicyId or explicitly remove the old policy."
    }
} else {
    $policyBody = @{
        oidc_policy = @{
            issuer = $OidcIssuer
            audiences = @($OidcAudience)
            subject = $OidcSubject
        }
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-DatabricksJson -Arguments @(
        "account", "service-principal-federation-policy", "create", $principalId,
        "--policy-id", $PolicyId,
        "--description", $PolicyDescription,
        "--json", $policyBody,
        "--profile", $AccountProfile,
        "--output", "json"
    ) | Out-Null
}

Write-Host "4/9 Validate account-level configuration"
$verifiedAssignments = @(
    Invoke-DatabricksJson -Arguments @(
        "account", "workspace-assignment", "list", $WorkspaceId,
        "--profile", $AccountProfile,
        "--output", "json"
    )
)
$verifiedAssignment = $verifiedAssignments | Where-Object {
    [string]$_.principal.principal_id -eq $principalId -and
    $_.permissions -contains "USER"
}
if (-not $verifiedAssignment) {
    throw "Workspace assignment validation failed"
}
$verifiedPolicies = @(
    Invoke-DatabricksJson -Arguments @(
        "account", "service-principal-federation-policy", "list", $principalId,
        "--profile", $AccountProfile,
        "--output", "json"
    )
)
if (-not ($verifiedPolicies | Where-Object { $_.policy_id -eq $PolicyId })) {
    throw "Federation policy validation failed"
}

$previousHost = $env:DATABRICKS_HOST
$previousAuthType = $env:DATABRICKS_AUTH_TYPE
try {
    $env:DATABRICKS_HOST = $WorkspaceHost
    $env:DATABRICKS_AUTH_TYPE = "azure-cli"

    Write-Host "5/9 Validate workspace authentication"
    Invoke-DatabricksJson -Arguments @("current-user", "me", "--output", "json") | Out-Null

    Write-Host "6/9 Grant SQL Warehouse CAN_USE"
    $warehousePermissionBody = @{
        access_control_list = @(
            @{
                service_principal_name = $clientId
                permission_level = "CAN_USE"
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-DatabricksJson -Arguments @(
        "permissions", "update", "warehouses", $WarehouseId,
        "--json", $warehousePermissionBody,
        "--output", "json"
    ) | Out-Null

    Write-Host "7/9 Create or reuse schema"
    $schemaObject = Invoke-DatabricksJson -AllowFailure -Arguments @(
        "schemas", "get", "$Catalog.$Schema", "--output", "json"
    )
    if (-not $schemaObject) {
        Invoke-DatabricksJson -Arguments @(
            "schemas", "create", $Schema, $Catalog,
            "--comment", "AKS federation access",
            "--output", "json"
        ) | Out-Null
    }

    Write-Host "8/9 Grant Unity Catalog access"
    Add-UnityCatalogGrant -SecurableType "catalog" -FullName $Catalog `
        -Privilege "USE_CATALOG" -Principal $clientId
    Add-UnityCatalogGrant -SecurableType "schema" -FullName "$Catalog.$Schema" `
        -Privilege "USE_SCHEMA" -Principal $clientId

    if (-not $SkipTableProvisioning) {
        Write-Host "9/9 Start the warehouse, provision the table, and validate"
        Invoke-DatabricksJson -Arguments @(
            "warehouses", "start", $WarehouseId,
            "--timeout", "20m",
            "--output", "json"
        ) | Out-Null
        $SeedMessageSql = ConvertTo-SqlString -Value $SeedMessage
        Invoke-SqlStatement -Statement "CREATE TABLE IF NOT EXISTS $CatalogSql.$SchemaSql.$TableSql (id INT, message STRING) USING DELTA" | Out-Null
        $mergeStatement = "MERGE INTO $CatalogSql.$SchemaSql.$TableSql AS target USING (SELECT $SeedId AS id, $SeedMessageSql AS message) AS source ON target.id = source.id WHEN MATCHED THEN UPDATE SET message = source.message WHEN NOT MATCHED THEN INSERT (id, message) VALUES (source.id, source.message)"
        Invoke-SqlStatement -Statement $mergeStatement | Out-Null
        Add-UnityCatalogGrant -SecurableType "table" -FullName $TableFullName `
            -Privilege "SELECT" -Principal $clientId
    } else {
        Write-Host "9/9 Skip table provisioning and validate grants"
    }

    $warehousePermissions = Invoke-DatabricksJson -Arguments @(
        "permissions", "get", "warehouses", $WarehouseId,
        "--output", "json"
    )
    $warehouseGrant = $warehousePermissions.access_control_list | Where-Object {
        $_.service_principal_name -eq $clientId -and
        $_.all_permissions.permission_level -contains "CAN_USE"
    }
    if (-not $warehouseGrant) {
        throw "Warehouse CAN_USE validation failed"
    }

    $catalogGrants = Invoke-DatabricksJson -Arguments @(
        "grants", "get", "catalog", $Catalog,
        "--output", "json"
    )
    $schemaGrants = Invoke-DatabricksJson -Arguments @(
        "grants", "get", "schema", "$Catalog.$Schema",
        "--output", "json"
    )
    if (-not ($catalogGrants.privilege_assignments | Where-Object {
        $_.principal -eq $clientId -and $_.privileges -contains "USE_CATALOG"
    })) {
        throw "Catalog USE_CATALOG validation failed"
    }
    if (-not ($schemaGrants.privilege_assignments | Where-Object {
        $_.principal -eq $clientId -and $_.privileges -contains "USE_SCHEMA"
    })) {
        throw "Schema USE_SCHEMA validation failed"
    }

    if (-not $SkipTableProvisioning) {
        $tableGrants = Invoke-DatabricksJson -Arguments @(
            "grants", "get", "table", $TableFullName,
            "--output", "json"
        )
        if (-not ($tableGrants.privilege_assignments | Where-Object {
            $_.principal -eq $clientId -and $_.privileges -contains "SELECT"
        })) {
            throw "Table SELECT validation failed"
        }
        $query = Invoke-SqlStatement -Statement "SELECT id, message FROM $CatalogSql.$SchemaSql.$TableSql ORDER BY id"
        $rows = @($query.result.data_array)
    } else {
        $rows = @()
    }
} finally {
    $env:DATABRICKS_HOST = $previousHost
    $env:DATABRICKS_AUTH_TYPE = $previousAuthType
}

$configuration.ServicePrincipalId = $principalId
$configuration.DatabricksClientId = $clientId
$configuration.SeedRows = $rows
[pscustomobject]$configuration