# Service Account Lifecycle Stages — Per Account Type

---

## Universal Lifecycle State Machine

All account types share the same 7 states. The transitions and SLAs differ per type.

```
                  ┌──────────────────────────────────────────────────────────┐
                  │                                                          │
  [Requestor]     ▼                                                          │
  ────────────► REQUEST ──────────────────────────────────────────► REJECTED │
                  │                                                          │
  [Line Mgr]      ▼                                                          │
  ────────────► PENDING_APPROVAL                                             │
                  │                                                          │
  [Security/IAM]  ▼  (privileged accounts only)                              │
  ────────────► PENDING_SECURITY_REVIEW ──────────────────────────► REJECTED │
                  │                                                          │
  [GitLab MR]     ▼                                                          │
  ────────────► PROVISIONING                                                 │
                  │                                                          │
  [Terraform OK]  ▼                                                          │
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
| `REQUEST` | Service account requested via Jira | `Open` | Requestor |
| `PENDING_APPROVAL` | Awaiting line manager + system owner approval | `Pending Approval` | Line Manager |
| `PENDING_SECURITY_REVIEW` | Awaiting Information Security Team review (privileged only) | `Security Review` | InfoSec / IAM Team |
| `PROVISIONING` | GitLab pipeline running Terraform apply | `In Progress` | Automation |
| `ACTIVE` | Account exists and is in use | `Active` | Technical Owner |
| `UNDER_REVIEW` | Periodic review triggered automatically | `Under Review` | Technical + Business Owner |
| `SUSPENDED` | Account disabled pending investigation | `Suspended` | InfoSec |
| `DECOMMISSIONED` | Account deleted, credentials revoked, Terraform state cleaned | `Closed` | Automation |
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

## Type 1: AD Service Accounts

**Used for:** Windows services (non-interactive), scheduled tasks, IIS app pools (where gMSA not applicable)

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required fields: service name, server(s), OU, privilege level, owner
  ▼
PENDING_APPROVAL (Line Manager + AD Ops)
  │  Privileged flag → Security Review
  ▼
PROVISIONING
  │  Terraform: activedirectory provider
  │  - Create account in designated OU
  │  - Set password via Delinea DSV (password never shown to requestor)
  │  - Set account flags: non-interactive, no-logon-allowed, DONT_EXPIRE_PASSWORD=false
  │  - Set description with Jira ticket reference
  │  - Assign to security groups per requested permissions
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
  │  Terraform: disable account → wait 30 days → delete
  │  Delinea: revoke and delete secret
  │  AD: account moved to "Disabled_SVC" OU for 30-day retention
```

**Privileged trigger:** Member of Domain Admins, Schema Admins, Backup Operators, or delegated sensitive OUs

**Naming convention:** `svc-{appname}-{env}` (e.g., `svc-billing-prod`)

---

## Type 2: Group Managed Service Accounts (gMSA)

**Used for:** SQL Server services, IIS app pools, Windows services on multiple servers

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required fields: service name, member servers (list), SPN requirements
  ▼
PENDING_APPROVAL
  │  Note: gMSA passwords managed by AD KDS root key — no Delinea needed
  ▼
PROVISIONING
  │  Terraform: activedirectory provider
  │  - New-ADServiceAccount -Name 'gmsa-{appname}' -DNSHostName ...
  │  - PrincipalsAllowedToRetrieveManagedPassword = member servers group
  │  - Set SPNs if required (e.g., HTTP, MSSQLSvc)
  │  - Install-ADServiceAccount via Chef on member servers
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
```

**Naming convention:** `gmsa-{appname}-{env}` (e.g., `gmsa-sqlreport-prod`)

**Key difference from AD SA:** No Delinea — password managed natively by AD KDS, never exposed.

---

## Type 3: Entra ID Service Principals (App Registrations)

**Used for:** OAuth 2.0 client credentials flows, API-to-API authentication, CI/CD service connections, SaaS integrations

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required fields: app name, API permissions needed, secret vs cert, owner
  ▼
PENDING_APPROVAL (Line Manager + Entra Admin)
  │  Privileged flag: Global Admin / Privileged Role Admin → Security Review
  ▼
PROVISIONING
  │  Terraform: azuread provider
  │  - azuread_application + azuread_service_principal
  │  - azuread_application_password OR azuread_application_certificate
  │  - azuread_app_role_assignment (API permissions)
  │  - Secret stored in Delinea DSV (for client_secret type)
  │  - Certificate uploaded from PKI, thumbprint stored in Delinea
  ▼
ACTIVE
  │  Client secret: Delinea rotates every 90 days
  │    - Delinea uses Entra ID REST API to create new secret, retire old
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

**Secret expiry maximum:** 2 years (Entra hard limit); target 90-day rotation via Delinea

---

## Type 4: Entra ID Managed Identities

**Used for:** Azure VMs, App Services, AKS pods (Workload Identity), Functions — no credentials at all

### Lifecycle Specifics
```
REQUEST (Jira)
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
  │  System-assigned: decommissioned with resource
```

**Key advantage:** No credentials to rotate — preferred over Service Principals for Azure workloads.  
**Naming convention (user-assigned):** `mi-{appname}-{env}` (e.g., `mi-reportgen-prod`)

---

## Type 5: AWS IAM Users (Service — Legacy)

**Policy:** No new AWS IAM Users for service purposes. Existing ones must be migrated to IAM Roles.  
**Migration deadline:** Defined per Phase 1 rollout assessment.

### Lifecycle Specifics (for existing accounts only)
```
ACTIVE (existing)
  │  Delinea or AWS Secrets Manager stores access key + secret key
  │  Rotation: 30-day maximum via AWS SM rotation Lambda
  ▼
UNDER_REVIEW (quarterly — stricter due to legacy risk)
  │  Required action: assess migration to IAM Role
  │  - Migrated → DECOMMISSIONED (this account)
  │  - Still needed with justification → ACTIVE (+ Security approval)
  ▼
DECOMMISSIONED
  │  Delete access keys → delete IAM user
  │  Remove from all groups + inline policies
```

**Naming convention:** `svc-{appname}-{env}` in IAM (e.g., `svc-s3-exporter-prod`)

---

## Type 6: AWS IAM Roles

**Used for:** EC2 instance profiles, Lambda execution roles, ECS task roles, cross-account access, GitLab CI federation (OIDC)

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required: AWS account, service type (EC2/Lambda/ECS/OIDC), policies needed
  ▼
PENDING_APPROVAL (Cloud Platform team + Line Manager)
  │  Privileged: AdministratorAccess or * wildcard → Security Review
  ▼
PROVISIONING
  │  Terraform: aws provider
  │  - aws_iam_role (trust policy per service type)
  │  - aws_iam_policy + aws_iam_role_policy_attachment
  │  - EC2: aws_iam_instance_profile
  │  - GitLab OIDC: trust policy with sub condition
  │  - NO SECRETS — roles assumed via STS
  ▼
ACTIVE
  │  AWS Config rules monitor for overly-permissive policies
  │  SCPs at OU level enforce guardrails
  │  Drift: scheduled terraform plan detects manual changes
  ▼
UNDER_REVIEW (annual; quarterly for Admin-level)
  │  Review: trust policy still appropriate? permissions still needed?
  │  AWS IAM Access Analyzer findings reviewed
  ▼
DECOMMISSIONED
  │  Detach all policies → delete role
  │  Remove instance profile if applicable
```

**Naming convention:** `role-{appname}-{service}-{env}` (e.g., `role-billing-lambda-prod`)

---

## Type 7: Linux System Accounts

**Used for:** `systemd` service daemons, batch jobs, application process users (uid < 1000 convention)

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required: username, server(s) or server group, home dir, shell (/sbin/nologin default)
  ▼
PENDING_APPROVAL
  ▼
PROVISIONING
  │  Terraform: null_resource + Chef recipe OR direct SSH provider
  │  - useradd -r -s /sbin/nologin -d /opt/{appname} svc_{appname}
  │  - Set uid in reserved range (200-499 for service accounts)
  │  - SSH key pair generated; private key stored in Delinea
  │  - sudo rule added if required (targeted, not ALL)
  │  - /etc/sudoers.d/svc_{appname} with specific commands only
  ▼
ACTIVE
  │  No password (SSH key or no interactive login)
  │  If sudo needed: Delinea manages and rotates SSH key
  ▼
UNDER_REVIEW (annual)
  │  Confirm account still exists on servers, process still running
  ▼
DECOMMISSIONED
  │  userdel -r svc_{appname} via Chef
  │  Remove sudoers entry
  │  Delinea: delete SSH key secret
```

**Naming convention:** `svc_{appname}` (e.g., `svc_billing`, `svc_nginx`)

---

## Type 8: Database Service Accounts

**Used for:** Application-to-DB connections (SQL Server, PostgreSQL, Oracle, MongoDB)

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required: DB engine, instance, database, permissions (read/write/ddl), app name
  ▼
PENDING_APPROVAL (DBA team + Line Manager)
  │  DDL / Schema owner permissions → Security Review
  ▼
PROVISIONING
  │  Terraform provider per engine:
  │  - mssql provider (SQL Server)
  │  - postgresql provider (PostgreSQL)
  │  - oraclepaas provider (Oracle)
  │  - mongodbatlas provider (MongoDB Atlas)
  │  - CREATE USER → GRANT minimal roles
  │  - Password generated randomly → stored in Delinea
  │  - Delinea secret linked to DB template for rotation
  ▼
ACTIVE
  │  Delinea rotates password every 30 days
  │  Delinea heartbeat: verifies account can connect after rotation
  │  App retrieves password from Delinea API at startup
  ▼
UNDER_REVIEW (annual)
  │  DBA reviews: permissions still appropriate? DB still used?
  ▼
DECOMMISSIONED
  │  Revoke all grants → DROP USER
  │  Delinea: delete secret
```

**Naming convention:** `svc_{appname}_{db}` (e.g., `svc_billing_sqlprod`)

---

## Type 9: API Keys / Service Tokens

**Used for:** 3rd-party API integrations, internal service-to-service tokens, webhook secrets

### Lifecycle Specifics
```
REQUEST (Jira)
  │  Required: system/API name, purpose, consuming app, expiry, owner
  ▼
PENDING_APPROVAL
  ▼
PROVISIONING
  │  Terraform (where API supports it): generate via provider or local_file
  │  - Store in Delinea DSV immediately
  │  - CI/CD injects via Delinea SDK or env injection at runtime
  │  - NEVER stored in code or GitLab CI variables in plain text
  ▼
ACTIVE
  │  Delinea stores + provides to authorized consumers
  │  Rotation: depends on API (manual assisted by Delinea workflow or API-native)
  │  Maximum lifetime: 1 year (hard policy)
  ▼
UNDER_REVIEW (annual mandatory, quarterly recommended)
  │  Confirm: still in use? API still in service? owner still valid?
  ▼
DECOMMISSIONED
  │  Revoke token at source API
  │  Delete Delinea secret
  │  Remove from any consuming systems
```

---

## Summary Matrix

| Account Type | Delinea | AWS SM | AD Auto | No Secret | Review Cycle | Max Secret Age |
|---|:---:|:---:|:---:|:---:|---|---|
| AD Service Account | ✅ | ❌ | ❌ | ❌ | Annual | 30 days |
| gMSA | ❌ | ❌ | ✅ | — | Annual | 30 days (AD managed) |
| Entra SP (secret) | ✅ | ❌ | ❌ | ❌ | Annual | 90 days |
| Entra SP (cert) | ✅ | ❌ | ❌ | ❌ | Annual | 1 year (cert) |
| Entra Managed Identity | ❌ | ❌ | ❌ | ✅ | Annual | N/A |
| AWS IAM User (legacy) | ❌ | ✅ | ❌ | ❌ | Quarterly | 30 days |
| AWS IAM Role | ❌ | ❌ | ❌ | ✅ | Annual / Quarterly* | N/A |
| Linux System Account | ✅ (SSH key) | ❌ | ❌ | — | Annual | N/A |
| Database Account | ✅ | ❌ | ❌ | ❌ | Annual | 30 days |
| API Key / Token | ✅ | ✅** | ❌ | ❌ | Annual | 1 year |

*Quarterly for Admin-level roles  
**AWS-specific API integrations may use AWS SM instead
