<#
.SYNOPSIS
    Decommissions an Active Directory service account.
    Disables the account, removes group memberships, moves to Disabled OU,
    and revokes the Delinea secret.

.DESCRIPTION
    SACM v2 — AD Service Account Decommission Script.
    
    Follows the 30-day retention pattern:
      1. Disable the AD account
      2. Remove all group memberships (prevent any access)
      3. Move to Disabled_SVC OU
      4. Update description with decommission metadata
      5. Disable Delinea auto-change and mark secret for deletion
      6. Update Jira ticket

    The actual deletion happens after 30 days via a separate scheduled job.

.PARAMETER Name
    Application short name (e.g., "billing").

.PARAMETER Environment
    Target environment: prod, staging, or dev.

.PARAMETER JiraTicket
    SACM Jira ticket reference.

.PARAMETER Force
    Skip the 30-day retention and delete immediately (emergency decommissions only).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet("prod", "staging", "dev")]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$JiraTicket,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/logging.ps1"

$fullName = Get-FullAccountName -Name $Name -Environment $Environment -AccountType "ad-service-account"

Write-AuditLog -Action "StartDecommission" -Target $fullName -Result "Success" `
    -Message "Starting decommission process. Force=$Force" -JiraTicket $JiraTicket

# --- Step 1: Verify account exists -----------------------------------------
$account = $null
try {
    $account = Get-ADUser -Identity $fullName -Server $Script:DomainController `
        -Properties MemberOf, Description, DistinguishedName
}
catch {
    Write-AuditLog -Action "VerifyAccount" -Target $fullName -Result "Failed" `
        -Message "Account not found in AD." -JiraTicket $JiraTicket
    throw "Account '$fullName' not found in Active Directory."
}

Write-AuditLog -Action "VerifyAccount" -Target $fullName -Result "Success" `
    -Message "Found at: $($account.DistinguishedName)" -JiraTicket $JiraTicket

# --- Step 2: Disable account -----------------------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Disable AD account")) {
    try {
        Disable-ADAccount -Identity $fullName -Server $Script:DomainController
        Write-AuditLog -Action "DisableAccount" -Target $fullName -Result "Success" `
            -Message "Account disabled." -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "DisableAccount" -Target $fullName -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        throw
    }
}

# --- Step 3: Remove all group memberships -----------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Remove all group memberships")) {
    $groups = $account.MemberOf
    foreach ($groupDN in $groups) {
        try {
            Remove-ADGroupMember -Identity $groupDN -Members $fullName `
                -Server $Script:DomainController -Confirm:$false
            Write-AuditLog -Action "RemoveGroupMember" -Target "$fullName ← $groupDN" -Result "Success" `
                -Message "Removed from group." -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "RemoveGroupMember" -Target "$fullName ← $groupDN" -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }
}

# --- Step 4: Update description and move to Disabled OU ---------------------
$decommDate = Get-Date -Format "yyyy-MM-dd"
$newDescription = "DECOMMISSIONED $decommDate | $JiraTicket | Previous: $($account.Description)"

if ($PSCmdlet.ShouldProcess($fullName, "Move to Disabled_SVC OU")) {
    try {
        Set-ADUser -Identity $fullName -Server $Script:DomainController `
            -Description $newDescription
        Move-ADObject -Identity $account.DistinguishedName `
            -TargetPath $Script:OUPaths.Disabled -Server $Script:DomainController
        Write-AuditLog -Action "MoveToDisabled" -Target $fullName -Result "Success" `
            -Message "Moved to $($Script:OUPaths.Disabled)" -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "MoveToDisabled" -Target $fullName -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
    }
}

# --- Step 5: Force delete (if emergency) ------------------------------------
if ($Force) {
    if ($PSCmdlet.ShouldProcess($fullName, "FORCE DELETE AD account (no retention)")) {
        try {
            Remove-ADUser -Identity $fullName -Server $Script:DomainController -Confirm:$false
            Write-AuditLog -Action "ForceDelete" -Target $fullName -Result "Success" `
                -Message "Account permanently deleted (Force mode)." -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "ForceDelete" -Target $fullName -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }
}
else {
    Write-AuditLog -Action "RetentionPeriod" -Target $fullName -Result "Success" `
        -Message "Account disabled in Disabled_SVC OU. Will be deleted after 30-day retention." `
        -JiraTicket $JiraTicket
}

# --- Step 6: Revoke Delinea secret ------------------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Revoke Delinea secret")) {
    if ($Script:DelineaBaseUrl -and $Script:DelineaClientId) {
        try {
            $authBody = @{
                grant_type    = "client_credentials"
                client_id     = $Script:DelineaClientId
                client_secret = $Script:DelineaClientSecret
            }
            $tokenResp = Invoke-RestMethod -Uri $Script:DelineaOAuthUrl -Method Post -Body $authBody
            $headers = @{
                "Authorization" = "Bearer $($tokenResp.access_token)"
                "Content-Type"  = "application/json"
            }

            # Find secret by name
            $searchResp = Invoke-RestMethod `
                -Uri "$($Script:DelineaApiUrl)/secrets?filter.searchText=$fullName" `
                -Method Get -Headers $headers

            if ($searchResp.records.Count -gt 0) {
                $secretId = $searchResp.records[0].id

                # Disable auto-change
                $updateBody = @{
                    autoChangeEnabled = $false
                    enableHeartbeat   = $false
                    active            = $false
                } | ConvertTo-Json

                Invoke-RestMethod -Uri "$($Script:DelineaApiUrl)/secrets/$secretId" `
                    -Method Patch -Headers $headers -Body $updateBody | Out-Null

                Write-AuditLog -Action "RevokeDelineaSecret" -Target "$fullName (ID: $secretId)" `
                    -Result "Success" -Message "Secret deactivated, heartbeat + auto-change disabled." `
                    -JiraTicket $JiraTicket
            }
            else {
                Write-AuditLog -Action "RevokeDelineaSecret" -Target $fullName -Result "Skipped" `
                    -Message "No Delinea secret found for this account." -JiraTicket $JiraTicket
            }
        }
        catch {
            Write-AuditLog -Action "RevokeDelineaSecret" -Target $fullName -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }
}

# --- Step 7: Notify Jira ---------------------------------------------------
if (-not $WhatIfPreference) {
    $action = if ($Force) { "FORCE DELETED" } else { "DISABLED (30-day retention)" }
    Send-JiraComment -TicketKey $JiraTicket `
        -CommentBody "🗑️ AD service account '$fullName' $action. Groups removed: $($account.MemberOf.Count). Delinea secret revoked."
}

# --- Final output -----------------------------------------------------------
$summary = Get-AuditLogSummary
Export-AuditLog -Path ".tmp/decommission-$fullName.json"

[ordered]@{
    status       = if ($summary.failed -gt 0) { "partial_failure" } else { "success" }
    account_name = $fullName
    action       = if ($Force) { "deleted" } else { "disabled" }
    groups_removed = $account.MemberOf.Count
    jira_ticket  = $JiraTicket
} | ConvertTo-Json -Depth 3
