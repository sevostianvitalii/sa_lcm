<#
.SYNOPSIS
    Drift detection for AD service accounts and gMSAs.
    Compares JSON declaration files against live Active Directory state.
    Replaces 'terraform plan' for the AD portion of SACM.

.DESCRIPTION
    Reads all account declaration files (JSON) from the specified directory,
    queries AD for each declared account, and reports any drift:
      - Account exists in declaration but not in AD
      - Account exists in AD but not in declarations (orphan)
      - Account properties differ (OU, groups, enabled status, description)

    Outputs a structured JSON drift report and optionally creates a Jira alert.

.PARAMETER DeclarationPath
    Path to the directory containing JSON declaration files.

.PARAMETER ReportPath
    Path to write the drift report JSON file.

.PARAMETER CreateJiraAlert
    If set, creates a Jira "Drift Alert" issue when drift is detected.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeclarationPath,

    [string]$ReportPath = ".tmp/ad-drift-report.json",

    [switch]$CreateJiraAlert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/logging.ps1"

Write-AuditLog -Action "StartDriftDetection" -Target $DeclarationPath -Result "Success" `
    -Message "Scanning declaration files for drift."

# --- Step 1: Load all declaration files -------------------------------------
$declarations = @()
$jsonFiles = Get-ChildItem -Path $DeclarationPath -Filter "*.json" -Recurse -ErrorAction SilentlyContinue

if ($jsonFiles.Count -eq 0) {
    Write-AuditLog -Action "LoadDeclarations" -Target $DeclarationPath -Result "Skipped" `
        -Message "No JSON declaration files found."
    exit 0
}

foreach ($file in $jsonFiles) {
    # Skip schema files
    if ($file.Name -eq "schema.json") { continue }

    try {
        $decl = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $declarations += [PSCustomObject]@{
            File        = $file.Name
            Declaration = $decl
        }
    }
    catch {
        Write-AuditLog -Action "ParseDeclaration" -Target $file.Name -Result "Failed" `
            -ErrorDetail $_.Exception.Message
    }
}

Write-AuditLog -Action "LoadDeclarations" -Target $DeclarationPath -Result "Success" `
    -Message "Loaded $($declarations.Count) declaration files."

# --- Step 2: Check each declaration against AD ------------------------------
$driftItems = [System.Collections.ArrayList]::new()

foreach ($item in $declarations) {
    $decl = $item.Declaration
    $fileName = $item.File

    # Determine account type and full name
    $accountType = $decl.type
    $prefix = switch ($accountType) {
        "ad-service-account" { "svc" }
        "gmsa"               { "gmsa" }
        default              { continue }
    }
    $fullName = "$prefix-$($decl.name)-$($decl.environment)"

    # Skip decommissioned declarations
    if ($decl.status -eq "decommissioned") {
        Write-AuditLog -Action "SkipDecommissioned" -Target $fullName -Result "Skipped"
        continue
    }

    # Query AD
    $adAccount = $null
    try {
        if ($accountType -eq "gmsa") {
            $adAccount = Get-ADServiceAccount -Identity $fullName -Server $Script:DomainController `
                -Properties Description, Enabled, DistinguishedName, ServicePrincipalNames `
                -ErrorAction SilentlyContinue
        }
        else {
            $adAccount = Get-ADUser -Identity $fullName -Server $Script:DomainController `
                -Properties Description, Enabled, DistinguishedName, MemberOf `
                -ErrorAction SilentlyContinue
        }
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # Account doesn't exist in AD
    }

    # --- Drift: Account declared but missing from AD ------------------------
    if (-not $adAccount) {
        [void]$driftItems.Add([ordered]@{
            account   = $fullName
            file      = $fileName
            drift     = "MISSING_IN_AD"
            expected  = "Account should exist (status: $($decl.status))"
            actual    = "Not found in Active Directory"
            severity  = "HIGH"
        })
        Write-AuditLog -Action "DriftCheck" -Target $fullName -Result "Failed" `
            -Message "DRIFT: Declared in $fileName but missing from AD."
        continue
    }

    # --- Drift: OU mismatch (AD SA only) ------------------------------------
    if ($accountType -eq "ad-service-account" -and $decl.ou_path) {
        $expectedOU = $decl.ou_path
        $actualOU = ($adAccount.DistinguishedName -replace "^CN=[^,]+,", "")
        if ($actualOU -ne $expectedOU) {
            [void]$driftItems.Add([ordered]@{
                account  = $fullName
                file     = $fileName
                drift    = "OU_MISMATCH"
                expected = $expectedOU
                actual   = $actualOU
                severity = "MEDIUM"
            })
        }
    }

    # --- Drift: Group membership mismatch (AD SA only) ----------------------
    if ($accountType -eq "ad-service-account" -and $decl.groups) {
        $expectedGroups = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$decl.groups, [StringComparer]::OrdinalIgnoreCase)
        $actualGroups = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]($adAccount.MemberOf ?? @()), [StringComparer]::OrdinalIgnoreCase)

        $missingGroups = $expectedGroups | Where-Object { -not $actualGroups.Contains($_) }
        $extraGroups   = $actualGroups   | Where-Object { -not $expectedGroups.Contains($_) }

        if ($missingGroups) {
            [void]$driftItems.Add([ordered]@{
                account  = $fullName
                file     = $fileName
                drift    = "MISSING_GROUP_MEMBERSHIPS"
                expected = $missingGroups
                actual   = "Not a member"
                severity = "HIGH"
            })
        }
        if ($extraGroups) {
            [void]$driftItems.Add([ordered]@{
                account  = $fullName
                file     = $fileName
                drift    = "EXTRA_GROUP_MEMBERSHIPS"
                expected = "Not declared"
                actual   = $extraGroups
                severity = "HIGH"
            })
        }
    }

    # --- Drift: Account disabled but declaration says active -----------------
    if ($decl.status -eq "active" -and -not $adAccount.Enabled) {
        [void]$driftItems.Add([ordered]@{
            account  = $fullName
            file     = $fileName
            drift    = "DISABLED_BUT_ACTIVE"
            expected = "Enabled (status: active)"
            actual   = "Account is disabled in AD"
            severity = "HIGH"
        })
    }
}

# --- Step 3: Check for orphans (in AD but not declared) ---------------------
# Scan all service accounts in managed OUs
foreach ($env in @("prod", "staging", "dev")) {
    $ouPath = $Script:OUPaths.ServiceAccounts[$env]
    if (-not $ouPath) { continue }

    try {
        $adAccounts = Get-ADUser -SearchBase $ouPath -Filter "SamAccountName -like 'svc-*'" `
            -Server $Script:DomainController -Properties SamAccountName

        foreach ($adAcct in $adAccounts) {
            $declaredNames = $declarations | Where-Object {
                $d = $_.Declaration
                "$( switch($d.type) { 'ad-service-account' { 'svc' }; 'gmsa' { 'gmsa' } })-$($d.name)-$($d.environment)" -eq $adAcct.SamAccountName
            }
            if (-not $declaredNames) {
                [void]$driftItems.Add([ordered]@{
                    account  = $adAcct.SamAccountName
                    file     = "NONE"
                    drift    = "ORPHAN_IN_AD"
                    expected = "Should have a declaration file"
                    actual   = "Exists in AD ($ouPath) but no JSON declaration found"
                    severity = "MEDIUM"
                })
            }
        }
    }
    catch {
        Write-AuditLog -Action "OrphanScan" -Target $ouPath -Result "Failed" `
            -ErrorDetail $_.Exception.Message
    }
}

# --- Step 4: Generate report ------------------------------------------------
$report = [ordered]@{
    timestamp       = (Get-Date -Format "o")
    declaration_path = $DeclarationPath
    total_declared  = $declarations.Count
    total_drift     = $driftItems.Count
    high_severity   = ($driftItems | Where-Object { $_.severity -eq "HIGH" }).Count
    medium_severity = ($driftItems | Where-Object { $_.severity -eq "MEDIUM" }).Count
    drift_items     = $driftItems
    status          = if ($driftItems.Count -eq 0) { "NO_DRIFT" } else { "DRIFT_DETECTED" }
}

# Write report file
$dir = Split-Path $ReportPath -Parent
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8

if ($driftItems.Count -eq 0) {
    Write-AuditLog -Action "DriftReport" -Target $DeclarationPath -Result "Success" `
        -Message "✅ No drift detected across $($declarations.Count) accounts."
}
else {
    Write-AuditLog -Action "DriftReport" -Target $DeclarationPath -Result "Failed" `
        -Message "⚠️ DRIFT DETECTED: $($driftItems.Count) items ($($report.high_severity) HIGH, $($report.medium_severity) MEDIUM)."

    # --- Step 5: Create Jira alert if requested -----------------------------
    if ($CreateJiraAlert -and $Script:JiraBaseUrl -and $Script:JiraApiToken) {
        try {
            $headers = @{
                "Authorization" = "Basic " + [Convert]::ToBase64String(
                    [Text.Encoding]::ASCII.GetBytes("${Script:JiraUserEmail}:${Script:JiraApiToken}")
                )
                "Content-Type"  = "application/json"
            }

            $driftSummary = ($driftItems | ForEach-Object { "$($_.account): $($_.drift)" }) -join "; "

            $issueBody = @{
                fields = @{
                    project   = @{ key = $Script:JiraProjectKey }
                    summary   = "DRIFT ALERT: $($driftItems.Count) AD service account(s) out of sync"
                    issuetype = @{ name = "Drift Alert" }
                    priority  = @{ name = if ($report.high_severity -gt 0) { "High" } else { "Medium" } }
                    description = @{
                        type = "doc"; version = 1
                        content = @(@{
                            type = "paragraph"
                            content = @(@{ type = "text"; text = "Drift detected: $driftSummary. Report: $($env:CI_PIPELINE_URL ?? 'local run')" })
                        })
                    }
                }
            } | ConvertTo-Json -Depth 8

            Invoke-RestMethod -Uri "$($Script:JiraBaseUrl)/rest/api/3/issue" `
                -Method Post -Headers $headers -Body $issueBody | Out-Null

            Write-AuditLog -Action "CreateJiraAlert" -Target "SACM" -Result "Success" `
                -Message "Drift alert created in Jira."
        }
        catch {
            Write-AuditLog -Action "CreateJiraAlert" -Target "SACM" -Result "Failed" `
                -ErrorDetail $_.Exception.Message
        }
    }
}

# Output report to stdout
$report | ConvertTo-Json -Depth 5

# Exit with code 2 if drift detected (matches terraform plan convention)
if ($driftItems.Count -gt 0) {
    exit 2
}
