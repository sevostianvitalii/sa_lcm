<#
.SYNOPSIS
    Creates a Group Managed Service Account (gMSA) in Active Directory.
    Replaces the Terraform modules/gmsa module.

.DESCRIPTION
    SACM v2 — gMSA Provisioning Script.

    gMSA passwords are managed natively by AD KDS (Key Distribution Service).
    No Delinea integration is needed — passwords are never exposed to humans.

    Performs:
      1. Validates naming convention
      2. Checks for existing gMSA (idempotency)
      3. Creates gMSA with specified DNS hostname and member servers
      4. Configures SPNs if required
      5. Updates Jira ticket

.PARAMETER Name
    Application short name (e.g., "sqlreport").

.PARAMETER Environment
    Target environment: prod, staging, or dev.

.PARAMETER DNSHostName
    DNS hostname for the gMSA (e.g., "gmsa-sqlreport-prod.bank.local").

.PARAMETER MemberServers
    Array of server names or group DN allowed to retrieve the gMSA password.

.PARAMETER SPNs
    Optional array of Service Principal Names (e.g., "MSSQLSvc/sqlserver01.bank.local:1433").

.PARAMETER JiraTicket
    SACM Jira ticket reference.

.PARAMETER TechnicalOwner
    Email or username of the technical owner.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[a-z][a-z0-9-]{2,20}$")]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet("prod", "staging", "dev")]
    [string]$Environment,

    [string]$DNSHostName,

    [Parameter(Mandatory)]
    [string[]]$MemberServers,

    [string[]]$SPNs = @(),

    [Parameter(Mandatory)]
    [string]$JiraTicket,

    [Parameter(Mandatory)]
    [string]$TechnicalOwner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/logging.ps1"

$fullName = Get-FullAccountName -Name $Name -Environment $Environment -AccountType "gmsa"

if (-not (Test-AccountName -FullName $fullName -AccountType "gmsa")) {
    Write-AuditLog -Action "ValidateName" -Target $fullName -Result "Failed" `
        -Message "Name '$fullName' does not match naming convention." -JiraTicket $JiraTicket
    throw "Invalid gMSA name: $fullName"
}

# Default DNS hostname if not provided
if (-not $DNSHostName) {
    $DNSHostName = "$fullName.$($Script:DomainFQDN)"
}

$description = "$fullName | Owner: $TechnicalOwner | Ticket: $JiraTicket"

Write-AuditLog -Action "StartProvisioning" -Target $fullName -Result "Success" `
    -Message "Starting gMSA provisioning. Members: $($MemberServers -join ', ')" -JiraTicket $JiraTicket

# --- Step 1: Check if gMSA already exists -----------------------------------
$existingGMSA = $null
try {
    $existingGMSA = Get-ADServiceAccount -Identity $fullName -Server $Script:DomainController `
        -ErrorAction SilentlyContinue
}
catch {
    # Expected — gMSA doesn't exist yet
}

if ($existingGMSA) {
    Write-AuditLog -Action "CheckExists" -Target $fullName -Result "Skipped" `
        -Message "gMSA already exists: $($existingGMSA.DistinguishedName)" -JiraTicket $JiraTicket

    # Update PrincipalsAllowed if needed (idempotent correction)
    if ($PSCmdlet.ShouldProcess($fullName, "Update PrincipalsAllowedToRetrieveManagedPassword")) {
        try {
            # Build principals group or individual entries
            $principals = $MemberServers | ForEach-Object {
                (Get-ADComputer -Identity $_ -Server $Script:DomainController).DistinguishedName
            }
            Set-ADServiceAccount -Identity $fullName -Server $Script:DomainController `
                -PrincipalsAllowedToRetrieveManagedPassword $principals
            Write-AuditLog -Action "UpdatePrincipals" -Target $fullName -Result "Success" `
                -Message "Updated allowed member servers." -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "UpdatePrincipals" -Target $fullName -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }

    $summary = Get-AuditLogSummary
    Export-AuditLog -Path ".tmp/provision-$fullName.json"
    $summary | ConvertTo-Json -Depth 3
    exit 0
}

# --- Step 2: Resolve member server principals --------------------------------
$principalsDN = @()
foreach ($server in $MemberServers) {
    try {
        $computer = Get-ADComputer -Identity $server -Server $Script:DomainController
        $principalsDN += $computer.DistinguishedName
        Write-AuditLog -Action "ResolveMember" -Target $server -Result "Success" `
            -Message "Resolved to: $($computer.DistinguishedName)" -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "ResolveMember" -Target $server -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        throw "Cannot resolve member server '$server' in AD."
    }
}

# --- Step 3: Create gMSA ---------------------------------------------------
if ($PSCmdlet.ShouldProcess($fullName, "Create gMSA")) {
    try {
        $gmsaParams = @{
            Name                                     = $fullName
            DNSHostName                              = $DNSHostName
            Description                              = $description
            PrincipalsAllowedToRetrieveManagedPassword = $principalsDN
            Enabled                                  = $true
            Server                                   = $Script:DomainController
        }

        # Place in the gMSA OU
        $ouPath = $Script:OUPaths.gMSA[$Environment]
        if ($ouPath) {
            $gmsaParams["Path"] = $ouPath
        }

        New-ADServiceAccount @gmsaParams
        Write-AuditLog -Action "CreateGMSA" -Target $fullName -Result "Success" `
            -Message "gMSA created. DNS: $DNSHostName. Members: $($MemberServers -join ', ')" `
            -JiraTicket $JiraTicket
    }
    catch {
        Write-AuditLog -Action "CreateGMSA" -Target $fullName -Result "Failed" `
            -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        Send-JiraComment -TicketKey $JiraTicket `
            -CommentBody "❌ gMSA provisioning FAILED for $fullName. Error: $($_.Exception.Message)"
        throw
    }
}
else {
    Write-AuditLog -Action "CreateGMSA" -Target $fullName -Result "DryRun" `
        -Message "[WhatIf] Would create gMSA: $fullName" -JiraTicket $JiraTicket
}

# --- Step 4: Set SPNs if provided ------------------------------------------
if ($SPNs.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess($fullName, "Set SPNs: $($SPNs -join ', ')")) {
        try {
            Set-ADServiceAccount -Identity $fullName -Server $Script:DomainController `
                -ServicePrincipalNames @{ Add = $SPNs }
            Write-AuditLog -Action "SetSPNs" -Target $fullName -Result "Success" `
                -Message "SPNs set: $($SPNs -join ', ')" -JiraTicket $JiraTicket
        }
        catch {
            Write-AuditLog -Action "SetSPNs" -Target $fullName -Result "Failed" `
                -ErrorDetail $_.Exception.Message -JiraTicket $JiraTicket
        }
    }
}

# --- Step 5: Notify Jira ---------------------------------------------------
if (-not $WhatIfPreference) {
    Send-JiraComment -TicketKey $JiraTicket `
        -CommentBody "✅ gMSA '$fullName' provisioned. DNS: $DNSHostName. Member servers: $($MemberServers -join ', '). SPNs: $($SPNs.Count). Password managed by AD KDS (no manual rotation needed)."
}

# --- Final output -----------------------------------------------------------
$summary = Get-AuditLogSummary
Export-AuditLog -Path ".tmp/provision-$fullName.json"

[ordered]@{
    status        = if ($summary.failed -gt 0) { "partial_failure" } else { "success" }
    account_name  = $fullName
    dns_hostname  = $DNSHostName
    member_servers = $MemberServers
    spns          = $SPNs
    jira_ticket   = $JiraTicket
    note          = "Password managed by AD KDS. No Delinea secret created."
} | ConvertTo-Json -Depth 3
