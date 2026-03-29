# Service Account Lifecycle Stages v2 — Per Account Type

> **v2 changes:** AD Service Account (Type 1) and gMSA (Type 2) provisioning updated from Terraform `hashicorp/ad` provider to native PowerShell (ActiveDirectory RSAT module). All other types unchanged.

---

## Universal Lifecycle State Machine

All account types share the same 7 states. The transitions and SLAs differ per type.

```
                  ┌──────────────────────────────────────────────────────────┐
                  │                                                          │
  [Requestor]     ▼                                                          │
  ────────────► REQUEST ──────────────────────────────────────────► REJECTED │
  (JSM portal     │                                                          │
   or Jira)       │                                                          │
  [Line Mgr]      ▼                                                          │
  ────────────► PENDING_APPROVAL                                             │
                  │                                                          │
  [Security/IAM]  ▼  (privileged accounts only)                              │
  ────────────► PENDING_SECURITY_REVIEW ──────────────────────────► REJECTED │
                  │                                                          │
  [GitLab MR]     ▼                                                          │
  ────────────► PROVISIONING (PS or TF)                                      │
                  │                                                          │
  [Script/TF OK]  ▼                                                          │
  ────────────► ACTIVE ────────────────────────────────────────────► SUSPENDED│
                  │                                                 (incident)│
  [Timer/Auto]    ▼                                                          │
  ────────────► UNDER_REVIEW                                                 │
                  │                                                          │
  [Owner]         ├──────────── Renew ──────────────────────────► ACTIVE    │
                  │                                                          │
                  └──────────── Decommission ──────────────────► DECOMMISSIONED
```

---

## Stage Definitions

| Stage | Description | Jira Status | Owner |
|---|---|---|---|
| `REQUEST` | Service account requested via JSM portal or Jira | `Open` | Requestor |
| `PENDING_APPROVAL` | Awaiting line manager + system owner approval | `Pending Approval` | Line Manager |
| `PENDING_SECURITY_REVIEW` | Awaiting Information Security Team review (privileged only) | `Security Review` | InfoSec / IAM Team |
| `PROVISIONING` | GitLab pipeline running PowerShell (AD) or Terraform (cloud/DB) | `In Progress` | Automation |
| `ACTIVE` | Account exists and is in use | `Active` | Technical Owner |
| `UNDER_REVIEW` | Periodic review triggered automatically | `Under Review` | Technical + Business Owner |
| `SUSPENDED` | Account disabled pending investigation | `Suspended` | InfoSec |
| `DECOMMISSIONED` | Account deleted, credentials revoked, state cleaned | `Closed` | Automation |
| `REJECTED` | Request denied at any approval stage | `Rejected` | Approver |

---

## SLA Targets

| Stage Transition | Standard Account | Privileged Account |
|---|---|---|
| REQUEST → PENDING_APPROVAL | Instant | Instant |
| PENDING_APPROVAL → PROVISIONING | 2 business days | 5 business days |
| PENDING_SECURITY_REVIEW | — | 3 business days |
| PROVISIONING → ACTIVE | 1 business day | 1 business day |
| ACTIVE → UNDER_REVIEW trigger | Every 365 days | Every 90 days |
| UNDER_REVIEW → DECOMMISSIONED (no response) | 14 days grace | 7 days grace |

---

## Type 1: AD Service Accounts _(v2 updated)_

**Used for:** Windows services (non-interactive), scheduled tasks, IIS app pools (where gMSA not applicable)

**v2 change:** Provisioning via PowerShell `New-ServiceAccount.ps1` on domain-joined GitLab runner (replaces Terraform `hashicorp/ad` provider).

### Lifecycle Specifics
```
REQUEST (Jira / JSM portal)
  │  Required fields: service name, server(s), OU, privilege level, owner
  ▼
PENDING_APPROVAL (Line Manager + AD Ops)
  │  Privileged flag → Security Review
  ▼
PROVISIONING
  │  GitLab CI → PowerShell on domain-joined runner:
  │  - execution/ad/New-ServiceAccount.ps1
  │  - Creates account in designated OU (New-ADUser)
  │  - Sets password via New-SecurePassword (32 chars, complexity enforced)
  │  - Registers password in Delinea via REST API (not TF provider)
  │  - Sets account flags: CannotChangePassword, PasswordNeverExpires=false
  │  - Sets description with Jira ticket reference
  │  - Assigns to security groups (Add-ADGroupMember)
  │  - Declaration stored as JSON in accounts/ad/{name}.json (version-controlled)
  ▼
ACTIVE
  │  Password stored + rotated in Delinea (30-day rotation)
  │  Delinea heartbeat monitors account health
  ▼
UNDER_REVIEW (annual trigger via Jira Automation)
  │  Owner confirms: still needed? same permissions? same servers?
  │  - Confirmed → ACTIVE (review date reset)
  │  - Permissions changed → new MR + re-approval
  │  - No response in 14 days → DECOMMISSIONED
  ▼
DECOMMISSIONED
  │  execution/ad/Remove-ServiceAccount.ps1:
  │  - Disable account → move to Disabled_SVC OU → delete after 30 days
  │  - Delinea: revoke and deactivate secret
  │  - Update JSON declaration: status = "decommissioned"
```

**Privileged trigger:** Member of Domain Admins, Schema Admins, Backup Operators, or delegated sensitive OUs

**Naming convention:** `svc-{appname}-{env}` (e.g., `svc-billing-prod`)

**Drift detection:** `Compare-ADState.ps1` — scheduled nightly via GitLab CI, checks JSON declarations against live AD state.

---

## Type 2: Group Managed Service Accounts (gMSA) _(v2 updated)_

**Used for:** SQL Server services, IIS app pools, Windows services on multiple servers

**v2 change:** Provisioning via PowerShell `New-GroupManagedSA.ps1` (replaces Terraform).

### Lifecycle Specifics
```
REQUEST (Jira / JSM portal)
  │  Required fields: service name, member servers (list), SPN requirements
  ▼
PENDING_APPROVAL
  │  Note: gMSA passwords managed by AD KDS root key — no Delinea needed
  ▼
PROVISIONING
  │  GitLab CI → PowerShell on domain-joined runner:
  │  - execution/ad/New-GroupManagedSA.ps1
  │  - New-ADServiceAccount -Name 'gmsa-{appname}-{env}' -DNSHostName ...
  │  - PrincipalsAllowedToRetrieveManagedPassword = member servers
  │  - Set SPNs if required (e.g., HTTP, MSSQLSvc)
  │  - Install-ADServiceAccount via Chef on member servers (unchanged)
  │  - Declaration stored as JSON in accounts/gmsa/{name}.json
  ▼
ACTIVE
  │  AD auto-rotates password every 30 days
  │  No Delinea integration — password never exposed
  ▼
UNDER_REVIEW (annual)
  │  Validate: member servers still correct? SPNs still needed?
  ▼
DECOMMISSIONED
  │  Remove-ADServiceAccount
  │  Uninstall from member servers via Chef
  │  Update JSON declaration: status = "decommissioned"
```

**Naming convention:** `gmsa-{appname}-{env}` (e.g., `gmsa-sqlreport-prod`)

**Key difference from AD SA:** No Delinea — password managed natively by AD KDS, never exposed.

---

## Type 3: Entra ID Service Principals (App Registrations)

**Used for:** OAuth 2.0 client credentials flows, API-to-API authentication, CI/CD service connections, SaaS integrations

**v2 note:** Unchanged from v1. Uses Terraform `hashicorp/azuread` provider (actively maintained, production-grade).

### Lifecycle Specifics
```
REQUEST (Jira / JSM portal)
  │  Required fields: app name, API permissions needed, secret vs cert, owner
  ▼
PENDING_APPROVAL (Line Manager + Entra Admin)
  │  Privileged flag: Global Admin / Privileged Role Admin → Security Review
  ▼
PROVISIONING
  │  Terraform: azuread provider (unchanged from v1)
  │  - azuread_application + azuread_service_principal
  │  - azuread_application_password OR azuread_application_certificate
  │  - azuread_app_role_assignment (API permissions)
  │  - Secret stored in Delinea DSV (via Terraform delinea provider)
  │  - Certificate uploaded from PKI, thumbprint stored in Delinea
  ▼
ACTIVE
  │  Client secret: Delinea rotates every 90 days
  │  Certificate: renewed via PKI 30 days before expiry
  │  Terraform manages secret version (keepers pattern)
  ▼
UNDER_REVIEW (annual)
  │  Review: API permissions still appropriate? Consent still valid?
  ▼
DECOMMISSIONED
  │  Terraform destroy: azuread_application (cascades SP + secrets)
  │  Delinea: secret deleted
  │  Verify no active tokens: Entra ID sign-in logs check
```

**Naming convention:** `sp-{appname}-{env}` (e.g., `sp-paymentapi-prod`)

---

## Type 4: Entra ID Managed Identities

**v2 note:** Unchanged from v1. Uses Terraform `hashicorp/azurerm` provider.

### Lifecycle Specifics
```
REQUEST (Jira / JSM portal)
  │  Required: resource name, identity type (system/user-assigned), RBAC roles needed
  ▼
PENDING_APPROVAL (lighter-weight — no secrets involved)
  ▼
PROVISIONING
  │  Terraform: azurerm provider
  │  - System-assigned: identity block in resource definition
  │  - User-assigned: azurerm_user_assigned_identity + azurerm_role_assignment
  │  - NO SECRETS — Managed Identity uses Azure IMDS token exchange
  ▼
ACTIVE
  │  No rotation needed — token managed by Azure platform
  │  RBAC assignments monitored for drift via scheduled terraform plan
  ▼
UNDER_REVIEW (annual)
  │  Confirm RBAC roles still appropriate
  ▼
DECOMMISSIONED
  │  Remove RBAC assignments → delete identity
```

**Naming convention (user-assigned):** `mi-{appname}-{env}` (e.g., `mi-reportgen-prod`)

---

## Type 5: AWS IAM Users (Service — Legacy)

**v2 note:** Unchanged from v1.

**Policy:** No new AWS IAM Users for service purposes. Existing ones must be migrated to IAM Roles.

### Lifecycle Specifics (for existing accounts only)
```
ACTIVE (existing)
  │  Delinea or AWS Secrets Manager stores access key + secret key
  │  Rotation: 30-day maximum via AWS SM rotation Lambda
  ▼
UNDER_REVIEW (quarterly — stricter due to legacy risk)
  │  Required action: assess migration to IAM Role
  ▼
DECOMMISSIONED
  │  Delete access keys → delete IAM user
```

---

## Type 6: AWS IAM Roles

**v2 note:** Unchanged from v1. Uses Terraform `hashicorp/aws` provider.

### Lifecycle Specifics
```
REQUEST (Jira / JSM portal)
  │  Required: AWS account, service type (EC2/Lambda/ECS/OIDC), policies needed
  ▼
PENDING_APPROVAL → PROVISIONING (Terraform) → ACTIVE → UNDER_REVIEW → DECOMMISSIONED
```

**Naming convention:** `role-{appname}-{service}-{env}` (e.g., `role-billing-lambda-prod`)

---

## Type 7: Linux System Accounts

**v2 note:** Unchanged from v1.

---

## Type 8: Database Service Accounts

**v2 note:** Unchanged from v1. Uses Terraform `cyrilgdn/postgresql` and `betr-io/mssql` providers.

---

## Type 9: API Keys / Service Tokens

**v2 note:** Unchanged from v1.

---

## Summary Matrix (v2)

| Account Type | Provisioning | Delinea | AWS SM | AD Auto | No Secret | Review Cycle | Max Secret Age |
|---|---|:---:|:---:|:---:|:---:|---|---|
| AD Service Account | **PowerShell** | ✅ | ❌ | ❌ | ❌ | Annual | 30 days |
| gMSA | **PowerShell** | ❌ | ❌ | ✅ | — | Annual | 30 days (AD managed) |
| Entra SP (secret) | Terraform | ✅ | ❌ | ❌ | ❌ | Annual | 90 days |
| Entra SP (cert) | Terraform | ✅ | ❌ | ❌ | ❌ | Annual | 1 year (cert) |
| Entra Managed Identity | Terraform | ❌ | ❌ | ❌ | ✅ | Annual | N/A |
| AWS IAM User (legacy) | Terraform | ❌ | ✅ | ❌ | ❌ | Quarterly | 30 days |
| AWS IAM Role | Terraform | ❌ | ❌ | ❌ | ✅ | Annual / Quarterly* | N/A |
| Linux System Account | TF/Chef | ✅ (SSH key) | ❌ | ❌ | — | Annual | N/A |
| Database Account | Terraform | ✅ | ❌ | ❌ | ❌ | Annual | 30 days |
| API Key / Token | Terraform | ✅ | ✅** | ❌ | ❌ | Annual | 1 year |

*Quarterly for Admin-level roles  
**AWS-specific API integrations may use AWS SM instead
