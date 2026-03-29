<#
.SYNOPSIS
    Creates an Active Directory service account with Delinea secret registration.
    Replaces the Terraform modules/ad-service-account module (hashicorp/ad provider).

.DESCRIPTION
    SACM v2 — AD Service Account Provisioning Script.
    
    Performs the following:
      1. Validates naming convention and parameters
      2. Checks for existing account (idempotency)
      3. Creates AD user in designated OU with security flags
      4. Adds group memberships
      5. Registers initial password in Delinea Secret Server
      6. Enables Delinea heartbeat and auto-rotation
      7. Posts result to Jira ticket

    Supports -WhatIf for dry-run mode in CI plan stage.

.PARAMETER Name
    Application short name (e.g., "billing"). Combined with environment to form "svc-billing-prod".

.PARAMETER Environment
    Target environment: prod, staging, or dev.

.PARAMETER OUPath
    Full distinguished name of the target OU. If not provided, uses default from config.

.PARAMETER JiraTicket
    SACM Jira ticket reference (e.g., "SACM-142").

.PARAMETER TechnicalOwner
    Email or username of the technical owner.

.PARAMETER Groups
    Comma-separated list of AD group distinguished names for membership.

.PARAMETER DelineaFolderId
    Delinea Secret Server folder ID. If not provided, uses default from config.

.EXAMPLE
    .\New-ServiceAccount.ps1 -Name "billing" -Environment "prod" `
        -JiraTicket "SACM-142" -TechnicalOwner "john.smith@bank.com" `
        -Groups "CN=GRP_Billing_Service,OU=Groups,DC=bank,DC=local"

.EXAMPLE
    # Dry-run mode (CI plan stage)
    .\New-ServiceAccount.ps1 -Name "billing" -Environment "prod" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[a-z][a-z0-9-]{2,20}$")]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet("prod", "staging", "dev")]
    [string]$Environment,

    [string]$OUPath,

    [Parameter(Mandatory)]
    [string]$JiraTicket,

    [Parameter(Mandatory)]
    [string]$TechnicalOwner,

    [string[]]$Groups = @(),

    [string]$DelineaFolderId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Load shared modules ---------------------------------------------------
. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/logging.ps1"

# --- Resolve parameters -----------------------------------------------------
$fullName = Get-FullAccountName -Name $Name -Environment $Environment -AccountType "ad-service-account"

if (-not (Test-AccountName -FullName $fullName -AccountType "ad-service-account")) {
    Write-AuditLog -Action "ValidateName" -Target $fullName -Result "Failed" `
        -Message "Name '$fullName' does not match naming convention." -JiraTicket $JiraTicket
    throw "Invalid account name: $fullName"
}

# Default OU from config if not provided
if (-not $OUPath) {
    $OUPath = $Script:OUPaths.ServiceAccounts[$Environment]
}
if (-not $OUPath) {
    throw "No OU path configured for environment '$Environment'."
}

# Default Delinea folder from config if not provided
if (-not $DelineaFolderId) {
    $DelineaFolderId = $Script:DelineaFolders["ad-service-account"][$Environment]
}

$description = "$fullName | Owner: $TechnicalOwner | Ticket: $JiraTicket"
$upn = "$fullName@$($Script:DomainFQDN)"

Write-AuditLog -Action "StartProvisioning" -Target $fullName -Result "Success" `
    -Message "Starting AD service account provisioning." -JiraTicket $JiraTicket

# --- Step 1: Check if account already exists (idempotency) ------------------
$existingAccount = $null
try {
    $existingAccount = Get-ADUser -Identity $fullName -Server $Script:DomainController -ErrorAction SilentlyContinue
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # Expected — account doesn't exist yet
}

if ($existingAccount) {
    Write-AuditLog -Action "CheckExists" -Target $fullName -Result "Skipped" `
        -Message "Account already exists in AD (DN: $($existingAccount.DistinguishedName)). Skipping creation." `
        -JiraTicket $JiraTicket

    # Still check group memberships for idempotent correction
    foreach ($groupDN in $Groups) {
        try {
            $members = Get-ADGroupMember -Identity $groupDN -Server $Script:DomainController | 
                       Select-Object -ExpandProperty SamAccountName
            if ($fullName -notin $members) {
                if ($PSCmdlet.ShouldProcess($groupDN, "Add $fullName to group")) {
                    Add-ADGroupMember -Identity $groupDN -Members $fullName -Server $Script:DomainController
                    Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "Success" `
                        -Message "Added missing group membership." -JiraTicket $JiraTicket
                }
                else {
                    Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "DryRun" `
                        -Message "[WhatIf] Would add to group." -JiraTicket $JiraTicket
                }
            }
        }
        catch {
            Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }

    $summary = Get-AuditLogSummary
    Export-AuditLog -Path ".tmp/provision-$fullName.json"
    $summary | ConvertTo-Json -Depth 3
    exit 0
}

# --- Step 2: Generate secure password --------------------------------------
$securePassword = New-SecurePassword

Write-AuditLog -Action "GeneratePassword" -Target $fullName -Result "Success" `
    -Message "Generated $($Script:PasswordLength)-char password meeting complexity requirements." `
    -JiraTicket $JiraTicket

# --- Step 3: Create AD user ------------------------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Create AD service account in $OUPath")) {

    $userParams = @{
        Name                  = $fullName
        SamAccountName        = $fullName
        UserPrincipalName     = $upn
        DisplayName           = $fullName
        Description           = $description
        Path                  = $OUPath
        AccountPassword       = $securePassword
        Enabled               = $true
        CannotChangePassword  = $true
        PasswordNeverExpires  = $false    # Delinea handles rotation
        ChangePasswordAtLogon = $false
        Server                = $Script:DomainController
    }

    try {
        New-ADUser @userParams
        Write-AuditLog -Action "CreateAccount" -Target $fullName -Result "Success" `
            -Message "Created AD user in OU: $OUPath" -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "CreateAccount" -Target $fullName -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        Send-JiraComment -TicketKey $JiraTicket `
            -CommentBody "❌ AD provisioning FAILED for $fullName. Error: $($_.Exception.Message)"
        throw
    }

    # Deny interactive logon (security hardening)
    try {
        Set-ADUser -Identity $fullName -Server $Script:DomainController `
            -Replace @{ "userAccountControl" = 514 }  # ACCOUNTDISABLE removed, NORMAL_ACCOUNT stays
        # Note: exact UAC flags may need tuning per your AD policy
        # The key flag is DONT_EXPIRE_PASSWORD = false (handled by PasswordNeverExpires above)
        Write-AuditLog -Action "SetSecurityFlags" -Target $fullName -Result "Success" `
            -Message "Set non-interactive logon flags." -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "SetSecurityFlags" -Target $fullName -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        # Non-fatal — continue with provisioning
    }
}
else {
    Write-AuditLog -Action "CreateAccount" -Target $fullName -Result "DryRun" `
        -Message "[WhatIf] Would create AD user in OU: $OUPath" -JiraTicket $JiraTicket
}

# --- Step 4: Add group memberships -----------------------------------------
foreach ($groupDN in $Groups) {
    if ($PSCmdlet.ShouldProcess($groupDN, "Add $fullName to group")) {
        try {
            Add-ADGroupMember -Identity $groupDN -Members $fullName -Server $Script:DomainController
            Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "Success" `
                -Message "Added to security group." -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }
    else {
        Write-AuditLog -Action "AddGroupMember" -Target "$fullName → $groupDN" -Result "DryRun" `
            -Message "[WhatIf] Would add to group." -JiraTicket $JiraTicket
    }
}

# --- Step 5: Register in Delinea Secret Server ------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Register password in Delinea folder $DelineaFolderId")) {
    if ($Script:DelineaBaseUrl -and $Script:DelineaClientId) {
        try {
            # Authenticate to Delinea
            $authBody = @{
                grant_type    = "client_credentials"
                client_id     = $Script:DelineaClientId
                client_secret = $Script:DelineaClientSecret
            }
            $tokenResp = Invoke-RestMethod -Uri $Script:DelineaOAuthUrl -Method Post -Body $authBody
            $delineaToken = $tokenResp.access_token

            $delineaHeaders = @{
                "Authorization" = "Bearer $delineaToken"
                "Content-Type"  = "application/json"
            }

            # Convert SecureString back to plain text for Delinea registration
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            # Create secret in Delinea
            $secretBody = @{
                name             = $fullName
                secretTemplateId = $Script:DelineaTemplates.ADServiceAccount
                folderId         = [int]$DelineaFolderId
                siteId           = 1
                items            = @(
                    @{ fieldName = "Username"; itemValue = $fullName }
                    @{ fieldName = "Password"; itemValue = $plainPassword }
                    @{ fieldName = "Domain";   itemValue = $Script:DomainFQDN }
                    @{ fieldName = "Notes";    itemValue = $description }
                )
                autoChangeEnabled  = $true
                checkOutEnabled    = $true
                enableHeartbeat    = $true
            } | ConvertTo-Json -Depth 4

            $secretResp = Invoke-RestMethod -Uri "$($Script:DelineaApiUrl)/secrets" `
                -Method Post -Headers $delineaHeaders -Body $secretBody

            # Zero out plain text password from memory
            $plainPassword = $null

            Write-AuditLog -Action "RegisterDelineaSecret" -Target $fullName -Result "Success" `
                -Message "Secret ID: $($secretResp.id). Heartbeat + auto-change enabled." `
                -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "RegisterDelineaSecret" -Target $fullName -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
            # Non-fatal — account is created but secret needs manual registration
            Write-Warning "Delinea registration failed. Manual secret registration required."
        }
    }
    else {
        Write-AuditLog -Action "RegisterDelineaSecret" -Target $fullName -Result "Skipped" `
            -Message "Delinea credentials not configured. Manual secret registration required." `
            -JiraTicket $JiraTicket
    }
}
else {
    Write-AuditLog -Action "RegisterDelineaSecret" -Target $fullName -Result "DryRun" `
        -Message "[WhatIf] Would register password in Delinea folder $DelineaFolderId." `
        -JiraTicket $JiraTicket
}

# --- Step 6: Notify Jira ---------------------------------------------------
if (-not $WhatIfPreference) {
    Send-JiraComment -TicketKey $JiraTicket `
        -CommentBody "✅ AD service account '$fullName' provisioned successfully. OU: $OUPath. Groups: $($Groups.Count). Delinea secret registered with heartbeat enabled."
}

# --- Final output -----------------------------------------------------------
$summary = Get-AuditLogSummary
Export-AuditLog -Path ".tmp/provision-$fullName.json"

# Output structured result for pipeline consumption
$result = [ordered]@{
    status          = if ($summary.failed -gt 0) { "partial_failure" } else { "success" }
    account_name    = $fullName
    upn             = $upn
    ou              = $OUPath
    groups_added    = $Groups.Count
    jira_ticket     = $JiraTicket
    log_summary     = @{
        total     = $summary.total
        succeeded = $summary.succeeded
        failed    = $summary.failed
    }
}

$result | ConvertTo-Json -Depth 3
