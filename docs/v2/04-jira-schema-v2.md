# Jira Project Schema v2 — Service Account Lifecycle Management (SACM)

> **v2 changes:** Added account-type routing in pipeline trigger automation. Updated webhook security to use `X-Automation-Webhook-Token` header. Added JSM self-service portal. Added SLA breach escalation automation.

---

## 1. Project Configuration

| Setting | Value |
|---|---|
| **Project Key** | `SACM` |
| **Project Name** | Service Account Lifecycle Management |
| **Project Type** | Business / Service Management |
| **Default Assignee** | IAM Operations Team |
| **Notification Scheme** | SACM Notifications (custom) |
| **Permission Scheme** | SACM Permissions (restricted) |

---

## 2. JSM Self-Service Portal _(v2 NEW)_

### Overview

A Jira Service Management (JSM) request type allows end users to submit service account requests through a clean, guided form without needing direct access to the SACM project.

### Request Type Configuration

| Setting | Value |
|---|---|
| **Portal Name** | IAM Self-Service |
| **Request Type** | New Service Account |
| **Issue Type (backing)** | Service Account Request |
| **Group** | Identity & Access |
| **Description** | Request a new service account for your application or service |

### Portal Form Fields

The portal form exposes a subset of fields with user-friendly labels:

| Portal Label | Maps to Field | Type | Help Text |
|---|---|---|---|
| What type of account do you need? | Account Type | Dropdown | Select the platform where your service runs |
| Which environment? | Environment | Dropdown | prod, staging, or dev |
| Application name | Account Name (auto-prefixed) | Text | Short name for your app (e.g., "billing") |
| Why do you need this account? | Justification | Text area | Business justification |
| Where will this account be used? | Target Servers / Resources | Text area | Server names, Azure resources, or AWS account |
| What permissions are needed? | Permissions Requested | Text area | Specific rights (e.g., read-only to DB, file share access) |
| Does this need admin-level access? | Privilege Level | Dropdown | Standard / Elevated / Privileged |
| Secret type | Credential Type | Dropdown | Password, SSH Key, Client Secret, Certificate, None |
| Your name (technical owner) | Technical Owner | User picker | Auto-populated from logged-in user |
| Your manager (business owner) | Business Owner | User picker | |

### Auto-Mapping Rules

| Trigger | Action |
|---|---|
| Portal submission | Set "Account Name" = `{prefix}-{portal_app_name}-{env}` based on Account Type |
| Account Type = "AD SA" or "gMSA" | Set "Secret Manager" = "Delinea" |
| Account Type = "Entra MI" or "AWS IAM Role" | Set "Credential Type" = "None" |
| Account Type = "AWS IAM User (Legacy)" | Block submission with warning: "Legacy IAM Users are prohibited. Use AWS IAM Role instead." |

---

## 3. Issue Types

| Issue Type | Icon | Purpose |
|---|---|---|
| `Service Account Request` | 🔑 | New service account creation |
| `Service Account Review` | 🔍 | Periodic revalidation (auto-created) |
| `Service Account Decommission` | 🗑️ | Planned or forced removal |
| `Drift Alert` | ⚠️ | Terraform/PowerShell drift detected (auto-created by pipeline) |
| `Emergency Break-Glass` | 🚨 | Emergency access with retroactive approval |
| `Secret Rotation` | 🔄 | Manual or failed rotation event |

---

## 4. Custom Fields

_(Unchanged from v1 — see original `04-jira-schema.md` for complete field definitions)_

---

## 5. Workflow: Service Account Request

_(Unchanged from v1 — see original `04-jira-schema.md` for statuses and transitions)_

---

## 6. Jira Automations (v2)

### 6.1 — Security Review Routing _(unchanged from v1)_

```yaml
Name: Route Privileged Requests to Security Review
Trigger: Issue Transitioned → Pending Approval
Condition:
  - Field condition: "Privilege Level" = "Privileged"
Action:
  - Transition issue to "Security Review"
  - Assign to: InfoSec Queue (round-robin user group)
  - Send email to: itsecurity@bank.com
  - Add comment: "Privileged account request requires InfoSec review. SLA: 3 business days."
```

### 6.2 — Trigger GitLab Pipeline (v2 — ROUTED by account type)

```yaml
Name: Trigger Provisioning Pipeline (Routed by Account Type)
Trigger: Issue Transitioned → Provisioning

# ── Branch 1: AD / gMSA → PowerShell pipeline ──
Condition: "Account Type" IN ("AD SA", "gMSA")
Action:
  - Send web request:
      URL: https://gitlab.bank.internal/api/v4/projects/{{config.SACM_PROJECT_ID}}/trigger/pipeline
      Method: POST
      Headers:
        Content-Type: application/json
      Body: |
        {
          "token": "{{config.GITLAB_TRIGGER_TOKEN}}",
          "ref": "main",
          "variables": [
            {"key": "JIRA_TICKET", "value": "{{issue.key}}"},
            {"key": "ACCOUNT_TYPE", "value": "{{issue.Account Type}}"},
            {"key": "ACCOUNT_NAME", "value": "{{issue.Account Name}}"},
            {"key": "ENV", "value": "{{issue.Environment}}"},
            {"key": "OWNER", "value": "{{issue.Technical Owner.emailAddress}}"},
            {"key": "PIPELINE_TYPE", "value": "powershell-ad"}
          ]
        }
  - Add comment: "🔧 PowerShell pipeline triggered for AD/gMSA provisioning."

# ── Branch 2: Entra / AWS / DB / Linux / API Key → Terraform pipeline ──
Condition: "Account Type" NOT IN ("AD SA", "gMSA")
Action:
  - Send web request:
      URL: https://gitlab.bank.internal/api/v4/projects/{{config.SACM_PROJECT_ID}}/trigger/pipeline
      Method: POST
      Headers:
        Content-Type: application/json
      Body: |
        {
          "token": "{{config.GITLAB_TRIGGER_TOKEN}}",
          "ref": "main",
          "variables": [
            {"key": "JIRA_TICKET", "value": "{{issue.key}}"},
            {"key": "ACCOUNT_TYPE", "value": "{{issue.Account Type}}"},
            {"key": "ACCOUNT_NAME", "value": "{{issue.Account Name}}"},
            {"key": "ENV", "value": "{{issue.Environment}}"},
            {"key": "OWNER", "value": "{{issue.Technical Owner.emailAddress}}"},
            {"key": "PIPELINE_TYPE", "value": "terraform"}
          ]
        }
  - Add comment: "⚙️ Terraform pipeline triggered for cloud/DB provisioning."
  - Set field: "Terraform MR Link" = "Pending — check GitLab pipeline."
```

### 6.3 — Mark Active on Pipeline Success (v2 — secure webhook)

```yaml
Name: Mark Account Active After Successful Provisioning
Trigger: Incoming webhook
  # v2: Uses secure X-Automation-Webhook-Token header (2025 migration)
  # GitLab pipeline callback sends POST with this header
  Webhook URL: (auto-generated by Jira Cloud)
  Authentication: X-Automation-Webhook-Token header
  
Condition:
  - webhookData.status == "success"

Action:
  - Find issue: key = {{webhookData.jira_ticket}}
  - Transition to "Active"
  - Set field: "Provision Date" = today
  - Set field: "Next Review Date" = today + 365 (or 90 for Privileged)
  - Set field: "Provisioning Status" = "Succeeded"
  - Add comment: "✅ Account provisioned successfully via {{webhookData.pipeline_type}}. Next review: {{issue.Next Review Date}}"
  - Send notification to: Technical Owner, Business Owner
```

### 6.4 — Handle Pipeline Failure (v2 — secure webhook)

```yaml
Name: Handle Pipeline Failure
Trigger: Incoming webhook
  Authentication: X-Automation-Webhook-Token header

Condition:
  - webhookData.status == "failed"

Action:
  - Find issue: key = {{webhookData.jira_ticket}}
  - Transition to "Open"
  - Set field: "Provisioning Status" = "Failed"
  - Add comment: "❌ Provisioning pipeline failed ({{webhookData.pipeline_type}}). Pipeline: {{webhookData.pipeline_url}}. Error: {{webhookData.error_message}}"
  - Assign to: IAM Operations Team
  - Send email to: iam-ops@bank.com
```

### 6.5 — Annual Review Scheduler _(unchanged from v1)_

### 6.6 — Review Grace Period Enforcement _(unchanged from v1)_

### 6.7 — Privileged Account Quarterly Review _(unchanged from v1)_

### 6.8 — Approaching Secret Expiry Alert _(unchanged from v1)_

### 6.9 — SLA Breach Escalation _(v2 NEW)_

```yaml
Name: Escalate Stale Approvals
Trigger: Scheduled — daily at 09:00
JQL Filter: project = SACM AND status = "Pending Approval" AND created <= -3d

Action:
  - Add comment: "⚠️ Approval pending > 3 business days. Escalating to business owner."
  - Re-assign to: {{issue.Business Owner}}
  - Send email to: {{issue.Business Owner.emailAddress}}
  - If created <= -5d:
      - Send email to: iam-ops@bank.com
      - Add comment: "🚨 Approval pending > 5 business days. IAM Operations notified."
```

### 6.10 — JSM Portal Auto-Validation _(v2 NEW)_

```yaml
Name: Validate JSM Service Account Request
Trigger: Issue Created (via JSM Portal)
Condition:
  - Issue Type = "Service Account Request"
  - Source = JSM Portal

Action:
  - Validate "Account Name" matches naming pattern
  - If Account Type = "AWS IAM User (Legacy)":
      - Reject with comment: "Legacy IAM Users are prohibited per policy. Please use AWS IAM Role."
      - Transition to "Rejected"
  - If valid:
      - Set "Account Name" = "{computed full name}" (e.g., svc-billing-prod)
      - Add comment: "Request submitted via IAM Self-Service Portal. Awaiting approval."
```

---

## 7. Permission Scheme

_(Unchanged from v1 — see original `04-jira-schema.md`)_

---

## 8. Dashboard Configuration

### SACM Operations Dashboard (v2)

**Gadgets:**
1. **Issue Statistics** — Status breakdown of all SACM issues (pie chart)
2. **Filter Results** — Accounts Under Review with overdue date
3. **Filter Results** — Drift Alerts open in last 7 days
4. **Two-Dimensional Stats** — Account Type × Environment matrix
5. **Heat Map** — Review date calendar (upcoming 30 days)
6. **Created vs Resolved** — Trend chart (last 90 days)
7. **Filter Results** — Pending Approvals > 3 days _(v2 new)_

**Key Filters (saved):**
- `SACM: Overdue Reviews` — `issuetype = "Service Account Review" AND status != Done AND created <= -14d`
- `SACM: Active Privileged Accounts` — `status = Active AND "Privilege Level" = Privileged`
- `SACM: Pending Approval > 2 days` — `status = "Pending Approval" AND created <= -2d`
- `SACM: Legacy AWS IAM Users` — `status = Active AND "Account Type" = "AWS IAM User (Legacy)"`
- `SACM: Provisioning Failures` — `"Provisioning Status" = Failed AND status = Open`
- `SACM: AD Drift Alerts` — `issuetype = "Drift Alert" AND summary ~ "AD service account"` _(v2 new)_
- `SACM: JSM Requests Pending` — `source = "JSM Portal" AND status = Open` _(v2 new)_
