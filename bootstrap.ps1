[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Install-MissingCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$DisplayName is already installed."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Install WinGet package $PackageId")) {
        return
    }

    Write-Host "Installing $DisplayName..."
    & winget install `
        --id $PackageId `
        --exact `
        --source winget `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install $DisplayName. WinGet exited with code $LASTEXITCODE."
    }

    Refresh-ProcessPath
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "WinGet is required. Install or update App Installer from Microsoft Store, then rerun this script."
}

$tools = @(
    @{ Command = "az"; DisplayName = "Azure CLI"; PackageId = "Microsoft.AzureCLI" },
    @{ Command = "databricks"; DisplayName = "Databricks CLI"; PackageId = "Databricks.DatabricksCLI" },
    @{ Command = "kubectl"; DisplayName = "Kubernetes CLI"; PackageId = "Kubernetes.kubectl" },
    @{ Command = "kubelogin"; DisplayName = "Azure Kubelogin"; PackageId = "Microsoft.Azure.Kubelogin" },
    @{ Command = "python"; DisplayName = "Python 3.12"; PackageId = "Python.Python.3.12" }
)

foreach ($tool in $tools) {
    Install-MissingCommand @tool
}

Refresh-ProcessPath
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    if ($WhatIfPreference) {
        Write-Host "PyYAML installation will be available after Python is installed."
        return
    }
    throw "Python was installed but is not available in this PowerShell session. Open a new PowerShell window and rerun bootstrap.ps1."
}

& python -c "import yaml" 2>$null
if ($LASTEXITCODE -ne 0) {
    if ($PSCmdlet.ShouldProcess("current Python environment", "Install PyYAML")) {
        Write-Host "Installing PyYAML..."
        & python -m pip install --disable-pip-version-check "PyYAML>=6,<7"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install PyYAML."
        }
    }
} else {
    Write-Host "PyYAML is already installed."
}

Write-Host "Prerequisite installation is complete. Sign in to Azure and Databricks before running run.ps1."