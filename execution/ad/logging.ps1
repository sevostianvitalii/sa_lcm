# ============================================================================
# SACM v2 — Structured JSON Logging
# Produces audit-grade log output for every provisioning action.
# Sourced by all AD provisioning scripts via: . $PSScriptRoot/logging.ps1
# ============================================================================

$Script:LogEntries = [System.Collections.ArrayList]::new()

function Write-AuditLog {
    <#
    .SYNOPSIS
        Writes a structured JSON log entry to stdout and collects it for final report.
    .PARAMETER Action
        The action being performed (e.g., "CreateAccount", "AddGroupMember", "RegisterSecret").
    .PARAMETER Target
        The object being acted upon (e.g., "svc-billing-prod", "CN=GRP_Billing_Service,...").
    .PARAMETER Result
        Outcome: "Success", "Failed", "Skipped", "DryRun".
    .PARAMETER Message
        Human-readable description of what happened.
    .PARAMETER JiraTicket
        Associated Jira ticket reference.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet("Success", "Failed", "Skipped", "DryRun")][string]$Result,
        [string]$Message = "",
        [string]$JiraTicket = "",
        [string]$ErrorDetail = ""
    )

    $entry = [ordered]@{
        timestamp   = (Get-Date -Format "o")                       # ISO 8601
        pipeline_id = $env:CI_PIPELINE_ID     ?? "local"
        job_id      = $env:CI_JOB_ID          ?? "local"
        triggered_by = $env:GITLAB_USER_LOGIN ?? $env:USERNAME ?? "unknown"
        action      = $Action
        target      = $Target
        result      = $Result
        message     = $Message
        jira_ticket = $JiraTicket
        error       = $ErrorDetail
    }

    $json = $entry | ConvertTo-Json -Compress
    
    # Write to stdout for GitLab CI job log capture
    switch ($Result) {
        "Failed"  { Write-Error   $json }
        "Skipped" { Write-Warning $json }
        default   { Write-Output  $json }
    }

    [void]$Script:LogEntries.Add($entry)
}

function Get-AuditLogSummary {
    <#
    .SYNOPSIS
        Returns a summary object with counts per result type and the full log entries.
        Used as the final output of a provisioning script.
    #>
    $summary = [ordered]@{
        total     = $Script:LogEntries.Count
        succeeded = ($Script:LogEntries | Where-Object { $_.result -eq "Success" }).Count
        failed    = ($Script:LogEntries | Where-Object { $_.result -eq "Failed" }).Count
        skipped   = ($Script:LogEntries | Where-Object { $_.result -eq "Skipped" }).Count
        dry_run   = ($Script:LogEntries | Where-Object { $_.result -eq "DryRun" }).Count
        entries   = $Script:LogEntries
    }

    return $summary
}

function Export-AuditLog {
    <#
    .SYNOPSIS
        Exports the collected log entries to a JSON file for artifact storage.
    .PARAMETER Path
        File path to write the log to (e.g., ".tmp/provision-log.json").
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $summary = Get-AuditLogSummary
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8

    Write-AuditLog -Action "ExportLog" -Target $Path -Result "Success" `
        -Message "Exported $($summary.total) log entries to $Path"
}

function Send-JiraComment {
    <#
    .SYNOPSIS
        Posts a comment to a Jira ticket via REST API.
        Used to update the SACM ticket with provisioning results.
    #>
    param(
        [Parameter(Mandatory)][string]$TicketKey,
        [Parameter(Mandatory)][string]$CommentBody
    )

    if (-not $Script:JiraBaseUrl -or -not $Script:JiraApiToken) {
        Write-AuditLog -Action "JiraComment" -Target $TicketKey -Result "Skipped" `
            -Message "Jira credentials not configured — skipping comment."
        return
    }

    $uri = "$($Script:JiraBaseUrl)/rest/api/3/issue/$TicketKey/comment"
    $headers = @{
        "Authorization" = "Basic " + [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes("${Script:JiraUserEmail}:${Script:JiraApiToken}")
        )
        "Content-Type"  = "application/json"
    }

    # Atlassian Document Format (ADF) for Jira Cloud
    $body = @{
        body = @{
            type    = "doc"
            version = 1
            content = @(
                @{
                    type    = "paragraph"
                    content = @(
                        @{
                            type = "text"
                            text = $CommentBody
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 6

    try {
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body | Out-Null
        Write-AuditLog -Action "JiraComment" -Target $TicketKey -Result "Success" `
            -Message "Posted comment to Jira ticket."
    }
    catch {
        Write-AuditLog -Action "JiraComment" -Target $TicketKey -Result "Failed" `
            -ErrorDetail $_.Exception.Message
    }
}
