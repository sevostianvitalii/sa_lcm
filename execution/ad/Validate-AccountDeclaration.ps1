<#
.SYNOPSIS
    Validates AD/gMSA account declaration JSON files against schema and naming conventions.
    Runs in the CI validate stage on every MR that touches accounts/ad/ or accounts/gmsa/.

.PARAMETER Path
    Directory containing JSON declaration files to validate.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/logging.ps1"

$errors = [System.Collections.ArrayList]::new()
$validated = 0

$jsonFiles = Get-ChildItem -Path $Path -Filter "*.json" -Recurse -ErrorAction SilentlyContinue

if ($jsonFiles.Count -eq 0) {
    Write-Output "No JSON declaration files found in $Path. Nothing to validate."
    exit 0
}

foreach ($file in $jsonFiles) {
    # Skip schema files
    if ($file.Name -eq "schema.json") { continue }

    $validated++
    $filePath = $file.FullName

    # --- Parse JSON ---------------------------------------------------------
    $decl = $null
    try {
        $decl = Get-Content $filePath -Raw | ConvertFrom-Json
    }
    catch {
        [void]$errors.Add("$($file.Name): Invalid JSON — $($_.Exception.Message)")
        continue
    }

    # --- Required fields ----------------------------------------------------
    $requiredFields = @("name", "environment", "type", "jira_ticket", "technical_owner", "status")
    foreach ($field in $requiredFields) {
        if (-not $decl.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($decl.$field)) {
            [void]$errors.Add("$($file.Name): Missing required field '$field'.")
        }
    }

    # --- Valid environment --------------------------------------------------
    if ($decl.environment -and $decl.environment -notin @("prod", "staging", "dev")) {
        [void]$errors.Add("$($file.Name): Invalid environment '$($decl.environment)'. Must be prod, staging, or dev.")
    }

    # --- Valid account type --------------------------------------------------
    if ($decl.type -and $decl.type -notin @("ad-service-account", "gmsa")) {
        [void]$errors.Add("$($file.Name): Invalid type '$($decl.type)'. Must be ad-service-account or gmsa.")
    }

    # --- Valid status -------------------------------------------------------
    if ($decl.status -and $decl.status -notin @("active", "decommissioned", "suspended")) {
        [void]$errors.Add("$($file.Name): Invalid status '$($decl.status)'. Must be active, decommissioned, or suspended.")
    }

    # --- Naming convention --------------------------------------------------
    if ($decl.name -and $decl.environment -and $decl.type) {
        $fullName = Get-FullAccountName -Name $decl.name -Environment $decl.environment -AccountType $decl.type
        if (-not (Test-AccountName -FullName $fullName -AccountType $decl.type)) {
            [void]$errors.Add("$($file.Name): Generated name '$fullName' doesn't match naming convention.")
        }

        # Filename should match the account name
        $expectedFileName = "$fullName.json"
        if ($file.Name -ne $expectedFileName) {
            [void]$errors.Add("$($file.Name): Filename should be '$expectedFileName' to match account name.")
        }
    }

    # --- Jira ticket format -------------------------------------------------
    if ($decl.jira_ticket -and $decl.jira_ticket -notmatch "^[A-Z]+-\d+$") {
        [void]$errors.Add("$($file.Name): Invalid jira_ticket format '$($decl.jira_ticket)'. Expected: PROJ-123.")
    }

    # --- AD SA specific: groups + ou_path -----------------------------------
    if ($decl.type -eq "ad-service-account") {
        if (-not $decl.PSObject.Properties["ou_path"] -or [string]::IsNullOrWhiteSpace($decl.ou_path)) {
            [void]$errors.Add("$($file.Name): AD service accounts require 'ou_path'.")
        }
        elseif ($decl.ou_path -notmatch "^OU=") {
            [void]$errors.Add("$($file.Name): ou_path should be a valid DN starting with 'OU='.")
        }

        if ($decl.groups -and $decl.groups -isnot [System.Collections.IEnumerable]) {
            [void]$errors.Add("$($file.Name): 'groups' must be an array.")
        }
    }

    # --- gMSA specific: member_servers --------------------------------------
    if ($decl.type -eq "gmsa") {
        if (-not $decl.PSObject.Properties["member_servers"] -or $decl.member_servers.Count -eq 0) {
            [void]$errors.Add("$($file.Name): gMSA requires at least one entry in 'member_servers'.")
        }
    }
}

# --- Report results ---------------------------------------------------------
Write-Output "=== Account Declaration Validation ==="
Write-Output "Files scanned: $validated"
Write-Output "Errors found:  $($errors.Count)"

if ($errors.Count -gt 0) {
    Write-Output ""
    Write-Output "ERRORS:"
    foreach ($err in $errors) {
        Write-Output "  ❌ $err"
    }
    Write-Output ""
    Write-Output "Validation FAILED."
    exit 1
}
else {
    Write-Output "✅ All declarations valid."
    exit 0
}
