# Service Account Lifecycle Management — Master Plan v2

> **Scope:** All service account types across hybrid banking infrastructure  
> **Model:** Hybrid Jira + GitLab + Terraform + PowerShell + Delinea  
> **Status:** Design v2.0 — 2026-03-29  
> **Changelog:** Replaced `hashicorp/ad` Terraform provider with native PowerShell (RSAT). Kept `hashicorp/azuread` for Entra ID. Added Phase 0 (runner setup). Added JSM self-service portal.

---

## 1. Problem Statement

Service accounts in a bank span multiple identity planes, clouds, and technologies. Without a unified lifecycle process, accounts accumulate without owners, passwords stagnate, privileges expand, and decommissioning never happens. The result is an expanding attack surface and compliance failures (PCI-DSS, SOX, ISO 27001).

**v2 addition:** The original design used the `hashicorp/ad` Terraform provider for on-prem AD provisioning. This provider is experimental, community-maintained, and has not been updated in over 2 years. It uses WinRM, which is fragile in enterprise networks. v2 replaces it with native PowerShell (ActiveDirectory RSAT module) executed via a domain-joined GitLab Runner — the standard enterprise approach.

---

## 2. Design Principles

| # | Principle | Implication |
|---|---|---|
| 1 | **Just-in-Time** | Accounts provisioned only when needed, decommissioned when done |
| 2 | **Least Privilege** | Minimum permissions at creation; no privilege creep |
| 3 | **Everything-as-Code** | All accounts declared in Terraform (cloud/DB) or JSON declarations (AD); GitLab = source of truth |
| 4 | **No Shared Accounts** | One account per workload/application |
| 5 | **No Long-lived Secrets** | Passwords/keys rotated automatically, managed in Delinea/AWS SM |
| 6 | **Full Audit Trail** | Every lifecycle event recorded in Jira and Git history |
| 7 | **Ownership is Mandatory** | Every account has a named technical owner and business owner |
| 8 | **Periodic Revalidation** | All accounts reviewed at least annually; privileged accounts quarterly |
| 9 | **Right Tool for Right Job** | Microsoft-native tooling for Microsoft products; Terraform for cloud/DB _(v2 new)_ |

---

## 3. Account Taxonomy

```
Service Accounts
├── Directory-based
│   ├── AD Service Accounts (on-prem Windows services)        ← PowerShell provisioning
│   ├── gMSA - Group Managed Service Accounts                 ← PowerShell provisioning
│   └── Entra ID Service Principals (app registrations)       ← Terraform (azuread)
├── Cloud-native
│   ├── Entra ID Managed Identities (System/User-assigned)    ← Terraform (azurerm)
│   ├── AWS IAM Users (service) [LEGACY - to be migrated]     ← Terraform (aws)
│   └── AWS IAM Roles (EC2, Lambda, ECS, cross-account)       ← Terraform (aws)
├── OS-level
│   ├── Windows Local Service Accounts (non-AD)
│   └── Linux System Accounts (uid < 1000, systemd services)
├── Application-level
│   ├── Database Service Accounts (SQL Server, PostgreSQL)     ← Terraform (postgresql/mssql)
│   └── API Keys / OAuth Clients / Service Tokens
└── Certificate-bound
    └── mTLS Service Identities (client certificates)
```

---

## 4. Architecture Overview (v2)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATION LAYER                           │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                   JIRA CLOUD + JSM                           │  │
│   │  Request → Approve → Provision → Active → Review → Decommission│
│   │  (Issue Types, Workflows, Automations, Webhooks)             │  │
│   │  JSM Portal: Self-service request form for end users         │  │
│   └─────────────────────────┬────────────────────────────────────┘  │
│                             │ Webhook (routed by account type)       │
└─────────────────────────────┼───────────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────────┐
│                         EXECUTION LAYER                              │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                     GITLAB CI/CD                             │  │
│   │  Pipeline triggered by Jira webhook (routed by PIPELINE_TYPE)│  │
│   │  Plan → Approve MR → Apply                                  │  │
│   └──────┬───────────────────────────────────┬──────────────────┘  │
│          │                                   │                       │
│   ┌──────▼──────────────────┐   ┌───────────▼───────────────────┐  │
│   │   POWERSHELL (AD)       │   │   TERRAFORM (Entra/AWS/DB)    │  │
│   │   Domain-joined runner  │   │   modules/entra-service-*     │  │
│   │   execution/ad/*.ps1    │   │   modules/aws-iam-role        │  │
│   │   accounts/ad/*.json    │   │   modules/database-account    │  │
│   │   accounts/gmsa/*.json  │   │   accounts/entra-sp/*.tf      │  │
│   └──────┬──────────────────┘   │   accounts/aws-roles/*.tf     │  │
│          │                       └───────────┬───────────────────┘  │
└──────────┼───────────────────────────────────┼──────────────────────┘
           │                                   │
┌──────────▼───────────────────────────────────▼──────────────────────┐
│                       IDENTITY PLANE                                 │
│                                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────┐  ┌─────────────┐ │
│  │  AD on-prem │  │  Entra ID    │  │  AWS IAM │  │  Linux / DB │ │
│  │  (RSAT/PS)  │  │  (azuread TF)│  │  (aws TF)│  │  (TF/Chef)  │ │
│  └─────────────┘  └──────────────┘  └──────────┘  └─────────────┘ │
└──────────┬──────────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────────────┐
│                       SECRETS LAYER                                  │
│                                                                     │
│  ┌──────────────────┐  ┌────────────────────┐  ┌────────────────┐  │
│  │  Delinea DSV/PAM │  │  AWS Secrets Mgr   │  │  GitLab CI     │  │
│  │  (AD, gMSA, DB)  │  │  (AWS IAM, Lambda) │  │  (tokens, keys)│  │
│  │  PS REST API(v2) │  │                    │  │                │  │
│  └──────────────────┘  └────────────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Lifecycle Summary (All Types)

```
┌─────────┐    ┌──────────┐    ┌───────────┐    ┌────────┐    ┌──────────┐    ┌─────────────┐
│ REQUEST │───▶│ APPROVAL │───▶│ PROVISION │───▶│ ACTIVE │───▶│  REVIEW  │───▶│ RENEW /     │
│ (JSM/   │    │ (2-eyes) │    │(PS or TF) │    │        │    │(quarterly│    │ DECOMMISSION│
│  Jira)  │    └──────────┘    └───────────┘    └────────┘    │/annual)  │    └─────────────┘
└─────────┘                                                   └──────────┘
```

---

## 6. Component Role Assignment (v2)

| Component | Role |
|---|---|
| **Jira Cloud** | Lifecycle state machine, approvals, audit trail, review scheduling |
| **JSM Portal** | Self-service request form for end users _(v2 new)_ |
| **GitLab** | Source of truth for account declarations (TF + JSON), CI/CD execution, 4-eyes via MR |
| **Terraform** | Deterministic provisioning for Entra ID, AWS, and Database accounts |
| **PowerShell (RSAT)** | Deterministic provisioning for on-prem AD accounts and gMSAs _(v2 new)_ |
| **Delinea DSV/PAM** | Credential vaulting, rotation, checkout for AD, gMSA, DB accounts |
| **AWS Secrets Manager** | AWS IAM key rotation, Lambda/ECS secret injection |
| **AD / Entra ID** | Identity authority for domain and cloud identities |
| **AWS IAM** | Cloud identity authority for AWS resources |

---

## 7. Phased Rollout (v2)

### Phase 0 — Domain-Joined Runner Setup _(v2 new — prerequisite)_
- [ ] Provision Windows Server VM (domain-joined to bank.local)
- [ ] Install RSAT Active Directory tools:
      `Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"`
- [ ] Install PowerShell 7.x (pwsh)
- [ ] Install GitLab Runner binary, register with GitLab instance
- [ ] Configure runner service to run as delegated AD service account:
      `.\gitlab-runner.exe install --user "BANK\svc-gitlab-adrunner" --password "..."`
- [ ] Delegate AD permissions to runner service account:
  - Create/Delete/Modify users in `OU=ServiceAccounts,*` OUs
  - Create/Delete `msDS-GroupManagedServiceAccount` objects in `OU=gMSA,*` OUs
  - Manage group membership in designated service account groups
  - **NOT** Domain Admin — principle of least privilege
- [ ] Tag runner with `domain-joined-runner` in GitLab
- [ ] Install Microsoft.Graph PowerShell SDK (for future Entra hybrid scenarios)
- [ ] Test: `Get-ADUser -Identity "svc-test" -Server dc01.bank.local` from runner
- [ ] Document runner in CMDB with SACM reference

### Phase 1 — Foundation (Months 1–2)
- [ ] GitLab repository structure and branching strategy
- [ ] PowerShell scripts for AD provisioning (`execution/ad/*.ps1`)
- [ ] JSON declaration format and schema (`accounts/ad/*.json`, `accounts/gmsa/*.json`)
- [ ] Terraform provider setup (Entra: azuread, AWS, DB — no hashicorp/ad)
- [ ] Jira project creation (issue types, workflows, fields)
- [ ] Jira ↔ GitLab webhook integration with account-type routing
- [ ] JSM portal for self-service requests
- [ ] Delinea integration for AD account password management (via PS REST API)
- [ ] Pilot: 5 AD service accounts end-to-end

### Phase 2 — Cloud Accounts (Months 3–4)
- [ ] Entra ID Service Principals lifecycle (Terraform azuread — unchanged from v1)
- [ ] AWS IAM Roles lifecycle (Terraform aws — unchanged from v1)
- [ ] AWS Secrets Manager rotation integration
- [ ] Entra Managed Identity lifecycle (lighter-weight path)
- [ ] Pilot: 5 cloud service accounts

### Phase 3 — OS & Application Accounts (Months 5–6)
- [ ] Linux system account lifecycle via Chef + Terraform
- [ ] Database account lifecycle (SQL Server, PostgreSQL)
- [ ] API key / token lifecycle
- [ ] Delinea integration expansion to DB accounts

### Phase 4 — Governance & Automation (Months 7–8)
- [ ] Quarterly/annual automated review scheduling via Jira Automation
- [ ] Drift detection pipeline (Terraform plan + Compare-ADState.ps1)
- [ ] Compliance reporting dashboards (Jira + GitLab)
- [ ] Orphan account detection script
- [ ] Full SOP documentation and team training

---

## 8. Security Controls

| Control | Mechanism |
|---|---|
| 4-eyes on all provisioning | GitLab MR requires 2 approvals |
| Privileged account approval | Dedicated Jira approval stage with Security team |
| Password rotation | Delinea automated rotation (AD/DB), AWS SM (cloud) |
| No hardcoded credentials | Terraform uses Delinea/SM providers; PS uses env vars; no secrets in git |
| Drift detection | Scheduled `terraform plan` (Entra/AWS/DB) + `Compare-ADState.ps1` (AD) |
| Access reviews | Jira Automation schedules review every 90/365 days |
| Separation of duties | Requestor ≠ Approver; Security approves privileged accounts |
| Emergency break-glass | Documented manual procedure, Jira emergency issue type |
| Runner least privilege | AD runner has delegated OU-level permissions only — not Domain Admin |

---

## 9. Compliance Mapping

| Standard | Requirement | Implementation |
|---|---|---|
| PCI-DSS 8.6 | Manage service accounts | Full lifecycle in Jira + Git |
| PCI-DSS 8.3 | Rotate credentials | Delinea / AWS SM automated rotation |
| SOX ITGC | Change management | GitLab MR = change record; Jira = approval |
| ISO 27001 A.9 | Access control | Jira workflow enforces approval + review |
| ISO 27001 A.12 | Audit logging | Git history + Jira audit log + Delinea vault logs |
| NIST SP 800-53 AC-2 | Account Management | Accounts provisioned, tracked, and reviewed via Jira |
| NIST SP 800-53 IA-5 | Authenticator Management | Enforcement of rotation, complexity via Delinea/AWS SM |
| NIST CSF PR.AA-1 | Identity & Credential Mgmt | Terraform + PowerShell declarative provisioning + lifecycle automation |
