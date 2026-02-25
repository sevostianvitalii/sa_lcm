# Service Account Lifecycle Management — Master Plan

> **Scope:** All service account types across hybrid banking infrastructure  
> **Model:** Hybrid Jira + GitLab + Terraform + Delinea  
> **Status:** Design v1.0 — 2026-02-25

---

## 1. Problem Statement

Service accounts in a bank span multiple identity planes, clouds, and technologies. Without a unified lifecycle process, accounts accumulate without owners, passwords stagnate, privileges expand, and decommissioning never happens. The result is an expanding attack surface and compliance failures (PCI-DSS, SOX, ISO 27001).

---

## 2. Design Principles

| # | Principle | Implication |
|---|---|---|
| 1 | **Just-in-Time** | Accounts provisioned only when needed, decommissioned when done |
| 2 | **Least Privilege** | Minimum permissions at creation; no privilege creep |
| 3 | **Everything-as-Code** | All accounts declared in Terraform; GitLab = source of truth |
| 4 | **No Shared Accounts** | One account per workload/application |
| 5 | **No Long-lived Secrets** | Passwords/keys rotated automatically, managed in Delinea/AWS SM |
| 6 | **Full Audit Trail** | Every lifecycle event recorded in Jira and Git history |
| 7 | **Ownership is Mandatory** | Every account has a named technical owner and business owner |
| 8 | **Periodic Revalidation** | All accounts reviewed at least annually; privileged accounts quarterly |

---

## 3. Account Taxonomy

```
Service Accounts
├── Directory-based
│   ├── AD Service Accounts (on-prem Windows services)
│   ├── gMSA - Group Managed Service Accounts (IIS, SQL, Exchange)
│   └── Entra ID Service Principals (app registrations, workload identity)
├── Cloud-native
│   ├── Entra ID Managed Identities (System-assigned / User-assigned)
│   ├── AWS IAM Users (service) [LEGACY - to be migrated]
│   └── AWS IAM Roles (EC2, Lambda, ECS, cross-account)
├── OS-level
│   ├── Windows Local Service Accounts (non-AD)
│   └── Linux System Accounts (uid < 1000, systemd services)
├── Application-level
│   ├── Database Service Accounts (SQL Server, PostgreSQL, Oracle, MongoDB)
│   └── API Keys / OAuth Clients / Service Tokens
└── Certificate-bound
    └── mTLS Service Identities (client certificates)
```

---

## 4. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATION LAYER                           │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                        JIRA                                  │  │
│   │  Request → Approve → Provision → Active → Review → Decommission│  │
│   │  (Issue Types, Workflows, Automations, Webhooks)             │  │
│   └─────────────────────────┬────────────────────────────────────┘  │
│                             │ Webhook                               │
└─────────────────────────────┼───────────────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────────────┐
│                         EXECUTION LAYER                              │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                     GITLAB CI/CD                             │  │
│   │  Pipeline triggered by Jira webhook                         │  │
│   │  Plan → Approve MR → Apply                                  │  │
│   └──────┬─────────────────────────────────────────────────────┘  │
│          │                                                          │
│   ┌──────▼───────────────────────────────────────────────────────┐  │
│   │                     TERRAFORM                                │  │
│   │  modules/ad-service-account                                 │  │
│   │  modules/gMSA                                               │  │
│   │  modules/entra-service-principal                            │  │
│   │  modules/aws-iam-role                                       │  │
│   │  modules/linux-service-account                              │  │
│   │  modules/database-account                                   │  │
│   └──────┬────────────────────────────────────────────────────┘  │
└──────────┼──────────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────────────┐
│                       IDENTITY PLANE                                 │
│                                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────┐  ┌─────────────┐ │
│  │  AD on-prem │  │  Entra ID    │  │  AWS IAM │  │  Linux / DB │ │
│  └─────────────┘  └──────────────┘  └──────────┘  └─────────────┘ │
└──────────┬──────────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────────────┐
│                       SECRETS LAYER                                  │
│                                                                     │
│  ┌──────────────────┐  ┌────────────────────┐  ┌────────────────┐  │
│  │  Delinea DSV/PAM │  │  AWS Secrets Mgr   │  │  GitLab CI     │  │
│  │  (AD, gMSA, DB)  │  │  (AWS IAM, Lambda) │  │  (tokens, keys)│  │
│  └──────────────────┘  └────────────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Lifecycle Summary (All Types)

```
┌─────────┐    ┌──────────┐    ┌───────────┐    ┌────────┐    ┌──────────┐    ┌─────────────┐
│ REQUEST │───▶│ APPROVAL │───▶│ PROVISION │───▶│ ACTIVE │───▶│  REVIEW  │───▶│ RENEW /     │
│         │    │ (2-eyes) │    │ (Terraform│    │        │    │(quarterly│    │ DECOMMISSION│
└─────────┘    └──────────┘    │  + Delinea│    └────────┘    │/annual)  │    └─────────────┘
                               └───────────┘                  └──────────┘
```

---

## 6. Component Role Assignment

| Component | Role |
|---|---|
| **Jira** | Lifecycle state machine, approvals, audit trail, review scheduling |
| **GitLab** | Source of truth for account declarations, CI/CD execution, 4-eyes via MR |
| **Terraform** | Deterministic provisioning and decommissioning of accounts |
| **Delinea DSV/PAM** | Credential vaulting, rotation, checkout for AD, gMSA, DB accounts |
| **AWS Secrets Manager** | AWS IAM key rotation, Lambda/ECS secret injection |
| **AD / Entra ID** | Identity authority for domain and cloud identities |
| **AWS IAM** | Cloud identity authority for AWS resources |

---

## 7. Phased Rollout

### Phase 1 — Foundation (Months 1–2)
- [ ] GitLab repository structure and branching strategy
- [ ] Terraform provider setup (AD, Entra, AWS, Linux via Chef/SSH)
- [ ] Jira project creation (issue types, workflows, fields)
- [ ] Jira ↔ GitLab webhook integration
- [ ] Delinea integration for AD account password management
- [ ] Pilot: 5 AD service accounts end-to-end

### Phase 2 — Cloud Accounts (Months 3–4)
- [ ] Entra ID Service Principals lifecycle
- [ ] AWS IAM Roles lifecycle
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
- [ ] Drift detection pipeline (Terraform plan on schedule)
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
| No hardcoded credentials | Terraform uses Delinea/SM providers; no secrets in git |
| Drift detection | Scheduled `terraform plan` → alerts on unexpected changes |
| Access reviews | Jira Automation schedules review every 90/365 days |
| Separation of duties | Requestor ≠ Approver; Security approves privileged accounts |
| Emergency break-glass | Documented manual procedure, Jira emergency issue type |

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
| NIST CSF PR.AA-1 | Identity & Credential Management | CI/CD native provisioning + lifecycle automation |
