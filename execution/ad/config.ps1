# ============================================================================
# SACM v2 — AD Provisioning Configuration
# Shared constants, naming conventions, and environment-specific settings.
# Sourced by all AD provisioning scripts via: . $PSScriptRoot/config.ps1
# ============================================================================

# --- Domain Configuration ---------------------------------------------------
$Script:DomainFQDN         = "bank.local"
$Script:DomainNetBIOS       = "BANK"
$Script:DomainController    = "dc01.bank.local"  # Preferred DC for writes
$Script:LDAPSPort           = 636

# --- OU Paths ---------------------------------------------------------------
$Script:OUPaths = @{
    ServiceAccounts = @{
        prod    = "OU=ServiceAccounts,OU=Prod,DC=bank,DC=local"
        staging = "OU=ServiceAccounts,OU=Staging,DC=bank,DC=local"
        dev     = "OU=ServiceAccounts,OU=Dev,DC=bank,DC=local"
    }
    gMSA = @{
        prod    = "OU=gMSA,OU=Prod,DC=bank,DC=local"
        staging = "OU=gMSA,OU=Staging,DC=bank,DC=local"
        dev     = "OU=gMSA,OU=Dev,DC=bank,DC=local"
    }
    Disabled = "OU=Disabled_SVC,DC=bank,DC=local"
}

# --- Naming Convention Rules ------------------------------------------------
# Pattern: svc-{appname}-{env} for AD SAs, gmsa-{appname}-{env} for gMSAs
$Script:NamingPatterns = @{
    "ad-service-account" = "^svc-[a-z][a-z0-9-]{2,20}-(prod|staging|dev)$"
    "gmsa"               = "^gmsa-[a-z][a-z0-9-]{2,20}-(prod|staging|dev)$"
}

# --- Password Policy --------------------------------------------------------
$Script:PasswordLength       = 32
$Script:PasswordSpecialChars = '!@#$%^&*()'
$Script:MinUpper             = 2
$Script:MinLower             = 2
$Script:MinDigit             = 2
$Script:MinSpecial           = 2

# --- Delinea Integration ---------------------------------------------------
$Script:DelineaBaseUrl       = $env:DELINEA_BASE_URL       # e.g. https://delinea.bank.local/SecretServer
$Script:DelineaApiUrl        = "$($Script:DelineaBaseUrl)/api/v1"
$Script:DelineaOAuthUrl      = "$($Script:DelineaBaseUrl)/oauth2/token"
$Script:DelineaClientId      = $env:DELINEA_CLIENT_ID
$Script:DelineaClientSecret  = $env:DELINEA_CLIENT_SECRET

# Delinea Secret Template IDs (must match your Secret Server configuration)
$Script:DelineaTemplates = @{
    ADServiceAccount = 6002   # AD Service Account + Heartbeat
    gMSA             = $null  # gMSA passwords managed by AD KDS — no Delinea secret
}

# Delinea Folder IDs per environment
$Script:DelineaFolders = @{
    "ad-service-account" = @{
        prod    = "1042"
        staging = "1043"
        dev     = "1044"
    }
}

# --- Jira Integration -------------------------------------------------------
$Script:JiraBaseUrl    = $env:JIRA_BASE_URL      # e.g. https://bank.atlassian.net
$Script:JiraApiToken   = $env:JIRA_API_TOKEN
$Script:JiraUserEmail  = $env:JIRA_USER_EMAIL    # Service account email for API auth
$Script:JiraProjectKey = "SACM"

# --- Validation Helpers -----------------------------------------------------
function Test-AccountName {
    <#
    .SYNOPSIS
        Validates an account name against the naming convention for its type.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FullName,

        [Parameter(Mandatory)]
        [ValidateSet("ad-service-account", "gmsa")]
        [string]$AccountType
    )

    $pattern = $Script:NamingPatterns[$AccountType]
    return $FullName -match $pattern
}

function Get-FullAccountName {
    <#
    .SYNOPSIS
        Builds the full account name from components.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][ValidateSet("ad-service-account", "gmsa")][string]$AccountType
    )

    $prefix = switch ($AccountType) {
        "ad-service-account" { "svc" }
        "gmsa"               { "gmsa" }
    }

    return "$prefix-$Name-$Environment"
}

function New-SecurePassword {
    <#
    .SYNOPSIS
        Generates a cryptographically secure password meeting complexity requirements.
    #>
    $chars  = 'abcdefghijklmnopqrstuvwxyz'
    $upper  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $digits = '0123456789'
    $special = $Script:PasswordSpecialChars
    $all = $chars + $upper + $digits + $special

    do {
        $bytes = New-Object byte[] $Script:PasswordLength
        $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)

        $password = -join ($bytes | ForEach-Object { $all[$_ % $all.Length] })

        # Verify complexity
        $hasUpper   = ($password.ToCharArray() | Where-Object { $upper.Contains($_) }).Count -ge $Script:MinUpper
        $hasLower   = ($password.ToCharArray() | Where-Object { $chars.Contains($_) }).Count -ge $Script:MinLower
        $hasDigit   = ($password.ToCharArray() | Where-Object { $digits.Contains($_) }).Count -ge $Script:MinDigit
        $hasSpecial = ($password.ToCharArray() | Where-Object { $special.Contains($_) }).Count -ge $Script:MinSpecial
    } while (-not ($hasUpper -and $hasLower -and $hasDigit -and $hasSpecial))

    return ConvertTo-SecureString $password -AsPlainText -Force
}
