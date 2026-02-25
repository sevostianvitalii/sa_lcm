# Jira Project Schema — Service Account Lifecycle Management (SACM)

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

## 2. Issue Types

| Issue Type | Icon | Purpose |
|---|---|---|
| `Service Account Request` | 🔑 | New service account creation |
| `Service Account Review` | 🔍 | Periodic revalidation (auto-created) |
| `Service Account Decommission` | 🗑️ | Planned or forced removal |
| `Drift Alert` | ⚠️ | Terraform drift detected (auto-created by pipeline) |
| `Emergency Break-Glass` | 🚨 | Emergency access with retroactive approval |
| `Secret Rotation` | 🔄 | Manual or failed rotation event |

---

## 3. Custom Fields

### Required on All Issue Types

| Field Name | Type | Values / Notes |
|---|---|---|
| `Account Type` | Select | AD SA, gMSA, Entra SP, Entra MI, AWS IAM Role, AWS IAM User (Legacy), Linux SA, DB Account, API Key |
| `Environment` | Select | prod, staging, dev |
| `Account Name` | Text | Auto-validated against naming convention |
| `Technical Owner` | User Picker | Must be active employee |
| `Business Owner` | User Picker | Accountable manager |
| `System / Application` | Text | Application this account serves |
| `Jira Ticket Reference` | Text | Self-referencing (populated post-create) |

### Required on `Service Account Request`

| Field Name | Type | Values / Notes |
|---|---|---|
| `Justification` | Text (long) | Business justification |
| `Target Servers / Resources` | Text | Where account will be used |
| `Permissions Requested` | Text | Specific rights needed |
| `Privilege Level` | Select | Standard / Elevated / Privileged |
| `Credential Type` | Select | Password, SSH Key, Client Secret, Certificate, None (MI/Role) |
| `Secret Manager` | Select | Delinea, AWS SM, None |
| `Terraform MR Link` | URL | Auto-populated by GitLab webhook |
| `Provisioning Status` | Select | Pending, Running, Succeeded, Failed |
| `Provision Date` | Date | Auto-set on ACTIVE transition |
| `Next Review Date` | Date | Auto-calculated on ACTIVE transition |

### Required on `Service Account Review`

| Field Name | Type | Notes |
|---|---|---|
| `Original Request Ticket` | Linked Issue | Link to creating SA-Request |
| `Last Review Date` | Date | Previous review date |
| `Review Decision` | Select | Renew, Modify, Decommission |
| `Permissions Change Required` | Select | Yes / No |
| `Owner Confirmation` | Checkbox | Owner confirmed account still needed |

### Required on `Emergency Break-Glass`

| Field Name | Type | Notes |
|---|---|---|
| `Incident Reference` | Text | Incident ticket or P-number |
| `Access Justification` | Text | Why emergency access is needed |
| `Access Duration` | Number | Hours (max 24) |
| `Approval Override` | User Picker | CISO or deputy |
| `Post-Access Audit Required` | Checkbox | Always yes |

---

## 4. Workflow: Service Account Request

### Statuses

```
Open → Pending Approval → Security Review → Provisioning → Active → Under Review → Decommissioned
                                                                              ↓
                                                                           Active (re-approved)
```

| Status | Category | Description |
|---|---|---|
| `Open` | To Do | Issue created, requestor filling details |
| `Pending Approval` | In Progress | Awaiting line manager + system owner sign-off |
| `Security Review` | In Progress | Awaiting InfoSec review (privileged accounts) |
| `Provisioning` | In Progress | GitLab pipeline running Terraform |
| `Active` | Done | Account exists and in use |
| `Under Review` | In Progress | Periodic revalidation in progress |
| `Suspended` | In Progress | Account disabled pending investigation |
| `Decommissioned` | Done | Account deleted, closed |
| `Rejected` | Done | Request denied |

### Transitions

| From | To | Trigger | Condition | Auto? |
|---|---|---|---|---|
| `Open` | `Pending Approval` | Submit Request | All required fields filled | Manual |
| `Pending Approval` | `Security Review` | Approve (Level 1) | Privilege Level = Privileged | Manual (Line Mgr) |
| `Pending Approval` | `Provisioning` | Approve (Level 1) | Privilege Level ≠ Privileged | Manual (Line Mgr) |
| `Security Review` | `Provisioning` | Approve (Level 2) | Always | Manual (InfoSec) |
| `Security Review` | `Rejected` | Reject | Always | Manual (InfoSec) |
| `Pending Approval` | `Rejected` | Reject | Always | Manual (Line Mgr) |
| `Provisioning` | `Active` | Pipeline Success | TF apply succeeded | Auto (webhook) |
| `Provisioning` | `Open` | Pipeline Failure | TF apply failed | Auto (webhook) |
| `Active` | `Under Review` | Review Timer | Review date reached | Auto (Automation) |
| `Under Review` | `Active` | Confirm Renew | Owner confirms | Manual (Owner) |
| `Under Review` | `Decommissioned` | Decommission | Owner requests or no response | Manual/Auto |
| `Active` | `Suspended` | Security Incident | Any | Manual (InfoSec) |
| `Suspended` | `Active` | Unsuspend | Investigation closed | Manual (InfoSec) |
| `Suspended` | `Decommissioned` | Decommission | Post-investigation | Manual (InfoSec) |

---

## 5. Screen Schemes

### Create Screen — Service Account Request
Fields visible when creating: Account Type, Environment, Justification, Technical Owner, Business Owner, System/Application, Permissions Requested, Privilege Level, Credential Type, Secret Manager, Target Servers/Resources

### Edit Screen
All custom fields visible to assigned team

### View Screen (Transition Screens)

**"Approve Level 1" transition screen:**
- Comment (required)
- Approve / Reject radio

**"Security Review Decision" transition screen:**
- Risk Assessment (text)
- Decision (Approve / Conditional / Reject)
- Conditions (text)

**"Review Complete" transition screen:**
- Review Decision
- Owner Confirmation
- Permissions Change Required
- Comment

---

## 6. Jira Automations

### 6.1 — Security Review Routing

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

### 6.2 — Trigger GitLab Pipeline on Approval

```yaml
Name: Trigger GitLab Provisioning Pipeline
Trigger: Issue Transitioned → Provisioning
Action:
  - Send web request:
      URL: https://gitlab.bank.internal/api/v4/projects/{{config.SACM_PROJECT_ID}}/pipeline
      Method: POST
      Headers:
        PRIVATE-TOKEN: {{config.GITLAB_API_TOKEN}}
      Body: |
        {
          "ref": "main",
          "variables": [
            {"key": "JIRA_TICKET", "value": "{{issue.key}}"},
            {"key": "ACCOUNT_TYPE", "value": "{{issue.fields.accountType}}"},
            {"key": "ENV", "value": "{{issue.fields.environment}}"},
            {"key": "ACCOUNT_NAME", "value": "{{issue.fields.accountName}}"}
          ]
        }
  - Add comment: "GitLab provisioning pipeline triggered. Monitor: {{response.body.web_url}}"
  - Set field: "Terraform MR Link" = {{response.body.web_url}}
```

### 6.3 — Mark Active on Pipeline Success (Inbound Webhook)

```yaml
Name: Mark Account Active After Successful Provisioning
Trigger: Incoming webhook from GitLab
  - URL: /rest/api/3/issue/{{JIRA_TICKET}}/transitions
  - Payload condition: status = "success"
Action:
  - Transition to "Active"
  - Set field: "Provision Date" = today
  - Set field: "Next Review Date" = today + 365 (or 90 for Privileged)
  - Add comment: "Account provisioned successfully. Next review: {{Next Review Date}}"
  - Send notification to: Technical Owner, Business Owner
```

### 6.4 — Mark Provisioning Failed

```yaml
Name: Handle Pipeline Failure
Trigger: Incoming webhook from GitLab, status = "failed"
Action:
  - Transition to "Open"
  - Set field: "Provisioning Status" = "Failed"
  - Add comment: "Provisioning pipeline failed. Pipeline: {{pipeline_url}}. Please correct the Terraform configuration and re-submit."
  - Assign to: IAM Operations Team
  - Send email to: iam-ops@bank.com
```

### 6.5 — Annual Review Scheduler

```yaml
Name: Schedule Annual Account Reviews
Trigger: Scheduled — daily at 08:00
JQL Filter: project = SACM AND issuetype = "Service Account Request" AND status = "Active" 
            AND "Next Review Date" <= now()
Action:
  - For each matched issue:
      - Create sub-task issue type "Service Account Review":
          Summary: "Annual Review — {{issue.fields.accountName}}"
          Account Type: {{issue.fields.accountType}}
          Technical Owner: {{issue.fields.technicalOwner}}
          Business Owner: {{issue.fields.businessOwner}}
          Original Request Ticket: {{issue.key}} (linked)
          Last Review Date: {{issue.fields.nextReviewDate}}
      - Transition parent to "Under Review"
      - Assign review ticket to Technical Owner
      - Add comment on parent: "Annual review triggered. Review ticket: {{child.key}}"
      - Send email to Technical Owner: 
          "Service account {{accountName}} requires annual review. 
           You have 14 days to complete the review.
           Review ticket: {{child.key}}"
```

### 6.6 — Review Grace Period Enforcement

```yaml
Name: Decommission Non-Responded Reviews
Trigger: Scheduled — daily at 08:00
JQL Filter: project = SACM AND issuetype = "Service Account Review" 
            AND status != "Done" 
            AND created <= -14d
Action:
  - Add comment: "Review SLA exceeded (14 days). Account will be decommissioned automatically."
  - Transition review ticket to "Done" (forced decommission)
  - Transition parent SA ticket to "Decommissioned"
  - Trigger decommission GitLab pipeline (webhook)
  - Send email to: Technical Owner, Business Owner, iam-ops@bank.com
  - Add parent comment: "AUTOMATIC DECOMMISSION — No review response within 14 days."
```

### 6.7 — Privileged Account Quarterly Review

```yaml
Name: Quarterly Reviews for Privileged Accounts
Trigger: Scheduled — first day of each quarter
JQL Filter: project = SACM AND issuetype = "Service Account Request" 
            AND status = "Active"
            AND "Privilege Level" = "Privileged"
            AND "Next Review Date" <= now()
Action:
  - Same as Annual Review Scheduler (6.5) but grace period = 7 days
```

### 6.8 — Approaching Secret Expiry Alert

```yaml
Name: Alert on Approaching Secret Expiry
Trigger: Scheduled — daily
JQL Filter: project = SACM AND status = "Active"
            AND "Credential Type" in ("Client Secret", "API Key")
            AND [Custom date field: Secret Expiry] <= 30d from now
Action:
  - Add comment: "⚠️ Secret expiry approaching in ≤30 days. Ensure Delinea rotation is configured."
  - Send email to: Technical Owner, iam-ops@bank.com
```

---

## 7. Permission Scheme

| Role | Create | View | Approve L1 | Approve L2 (Security) | Provision | Decommission |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Any Employee | ✅ | Own only | ❌ | ❌ | ❌ | ❌ |
| Line Manager | ✅ | Team | ✅ | ❌ | ❌ | ❌ |
| System/App Owner | ✅ | Own systems | ✅ | ❌ | ❌ | ❌ |
| IAM Operations | ✅ | All | ✅ | ❌ | ✅ | ✅ |
| InfoSec Team | View | All | ✅ | ✅ | ❌ | ✅ |
| SACM Automation | ❌ | All | ❌ | ❌ | ✅ | ✅ |
| Jira Admin | All | All | All | All | All | All |

---

## 8. Dashboard Configuration

### SACM Operations Dashboard

**Gadgets:**
1. **Issue Statistics** — Status breakdown of all SACM issues (pie chart)
2. **Filter Results** — Accounts Under Review with overdue date
3. **Filter Results** — Drift Alerts open in last 7 days
4. **Two-Dimensional Stats** — Account Type × Environment matrix
5. **Heat Map** — Review date calendar (upcoming 30 days)
6. **Created vs Resolved** — Trend chart (last 90 days)

**Key Filters (saved):**
- `SACM: Overdue Reviews` — `issuetype = "Service Account Review" AND status != Done AND created <= -14d`
- `SACM: Active Privileged Accounts` — `status = Active AND "Privilege Level" = Privileged`
- `SACM: Pending Approval > 2 days` — `status = "Pending Approval" AND created <= -2d`
- `SACM: Legacy AWS IAM Users` — `status = Active AND "Account Type" = "AWS IAM User (Legacy)"`
- `SACM: Provisioning Failures` — `"Provisioning Status" = Failed AND status = Open`
