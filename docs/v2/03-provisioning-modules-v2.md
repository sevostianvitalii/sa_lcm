# Provisioning Modules v2 — Terraform + PowerShell

> **v2 changes:** Renamed from "Terraform Modules" since AD provisioning now uses PowerShell. Removed `hashicorp/ad` provider. AD/gMSA modules replaced with PowerShell scripts + JSON declarations. Entra/AWS/DB modules unchanged.

---

## 1. Repository Structure (v2)

```
service-accounts/                          ← GitLab repo
├── .gitlab-ci.yml                         ← CI/CD pipeline (TF + PS stages)
├── README.md
├── terraform.tfvars.example
│
├── execution/                             ← PowerShell scripts (AD provisioning) [v2 NEW]
│   └── ad/
│       ├── config.ps1                     ← Shared configuration
│       ├── logging.ps1                    ← Structured JSON logging
│       ├── New-ServiceAccount.ps1         ← Create AD SA
│       ├── Remove-ServiceAccount.ps1      ← Decommission AD SA
│       ├── New-GroupManagedSA.ps1          ← Create gMSA
│       ├── Compare-ADState.ps1            ← Drift detection (replaces TF plan for AD)
│       └── Validate-AccountDeclaration.ps1 ← CI validation for JSON declarations
│
├── providers/                             ← Provider version pins (TF only)
│   ├── versions.tf                        ← No hashicorp/ad — removed in v2
│   └── providers.tf
│
├── modules/                               ← Terraform modules (Entra/AWS/DB only)
│   ├── entra-service-principal/           ← Unchanged (azuread provider)
│   ├── entra-managed-identity/            ← Unchanged (azurerm provider)
│   ├── aws-iam-role/                      ← Unchanged (aws provider)
│   ├── aws-iam-user-legacy/               ← Unchanged
│   ├── database-account/                  ← Unchanged
│   └── api-key-secret/                    ← Unchanged
│
├── accounts/                              ← Account declarations
│   ├── ad/                                ← JSON declarations [v2 NEW]
│   │   ├── schema.json                    ← JSON Schema for validation
│   │   ├── svc-billing-prod.json
│   │   ├── svc-reporting-prod.json
│   │   └── ...
│   ├── gmsa/                              ← JSON declarations [v2 NEW]
│   │   ├── schema.json
│   │   ├── gmsa-sqlreport-prod.json
│   │   └── ...
│   ├── entra-sp/                          ← Terraform .tf files (unchanged)
│   │   └── sp-paymentapi-prod.tf
│   ├── entra-mi/
│   ├── aws-roles/
│   ├── linux/
│   ├── databases/
│   └── api-keys/
│
├── environments/                          ← Per-env backend config (TF)
│   ├── prod/backend.tf
│   ├── staging/backend.tf
│   └── dev/backend.tf
│
├── scripts/                               ← Helper scripts
│   ├── drift-detect.sh                    ← TF drift detection (Entra/AWS/DB)
│   ├── orphan-detect.sh
│   └── validate-naming.py
│
└── docs/
    ├── 01-master-plan.md                  ← v1 (preserved)
    ├── ...
    └── v2/                                ← v2 documentation
        ├── 01-master-plan-v2.md
        └── ...
```

---

## 2. Provider Configuration (v2)

```hcl
# providers/versions.tf
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # NOTE: hashicorp/ad REMOVED in v2
    # On-prem AD provisioning now handled by PowerShell (execution/ad/*.ps1)

    # Entra ID / Azure AD — actively maintained, production-grade
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }

    # Azure Resources (for Managed Identities)
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }

    # AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }

    # PostgreSQL
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.21"
    }

    # SQL Server
    mssql = {
      source  = "betr-io/mssql"
      version = "~> 0.3"
    }

    # Delinea DSV (for secret registration — Entra/DB accounts)
    delinea = {
      source  = "DelineaXPM/delinea"
      version = "~> 0.1"
    }

    # Random (password/key generation)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # TLS (certificate/key generation)
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
```

---

## 3. PowerShell Module: AD Service Account (v2 NEW)

Replaces `modules/ad-service-account/`. See full script: `execution/ad/New-ServiceAccount.ps1`.

### Parameters

| Parameter | Type | Required | Description |
|---|---|:---:|---|
| `Name` | string | ✅ | Application short name (3-21 chars, lowercase alphanum + hyphens) |
| `Environment` | string | ✅ | prod, staging, or dev |
| `OUPath` | string | ❌ | Target OU DN. Defaults from config.ps1 |
| `JiraTicket` | string | ✅ | SACM ticket reference (e.g., SACM-142) |
| `TechnicalOwner` | string | ✅ | Owner email |
| `Groups` | string[] | ❌ | AD group DNs for membership |
| `DelineaFolderId` | string | ❌ | Delinea folder. Defaults from config.ps1 |
| `-WhatIf` | switch | — | Dry-run mode for CI plan stage |

### What It Does

1. Validates naming convention (`svc-{name}-{env}`)
2. Checks for existing account — skips creation if found (idempotent)
3. Generates 32-char cryptographic password
4. Creates AD user with security flags (CannotChangePassword, PasswordNeverExpires=false)
5. Adds group memberships
6. Registers password in Delinea via REST API (heartbeat + auto-change enabled)
7. Posts result to Jira ticket
8. Exports structured JSON audit log

### JSON Declaration Format

```json
{
  "name": "billing",
  "environment": "prod",
  "type": "ad-service-account",
  "description": "Billing service account for scheduled tasks",
  "ou_path": "OU=ServiceAccounts,OU=Prod,DC=bank,DC=local",
  "groups": [
    "CN=GRP_Billing_Service,OU=Groups,DC=bank,DC=local"
  ],
  "jira_ticket": "SACM-142",
  "technical_owner": "john.smith@bank.com",
  "business_owner": "jane.doe@bank.com",
  "delinea_folder_id": "1042",
  "privilege_level": "standard",
  "created_date": "2026-04-01",
  "status": "active"
}
```

---

## 4. PowerShell Module: gMSA (v2 NEW)

Replaces `modules/gmsa/`. See full script: `execution/ad/New-GroupManagedSA.ps1`.

### Key Difference from AD SA

- No Delinea integration — AD KDS manages the password natively
- Requires `member_servers` parameter (servers allowed to retrieve the gMSA password)
- Optional SPNs for Kerberos service authentication

### JSON Declaration Format

```json
{
  "name": "sqlreport",
  "environment": "prod",
  "type": "gmsa",
  "description": "SQL Reporting Services gMSA",
  "member_servers": ["SQLSERVER01", "SQLSERVER02"],
  "spns": ["MSSQLSvc/sqlserver01.bank.local:1433"],
  "jira_ticket": "SACM-155",
  "technical_owner": "dba.team@bank.com",
  "business_owner": "finance.director@bank.com",
  "privilege_level": "elevated",
  "created_date": "2026-04-01",
  "status": "active"
}
```

---

## 5. PowerShell Module: Drift Detection (v2 NEW)

See full script: `execution/ad/Compare-ADState.ps1`.

Replaces `terraform plan` for the AD portion. Checks:
- Account exists in declaration but not in AD → **MISSING_IN_AD** (HIGH)
- Account in wrong OU → **OU_MISMATCH** (MEDIUM)
- Group membership differs → **MISSING_GROUP_MEMBERSHIPS** / **EXTRA_GROUP_MEMBERSHIPS** (HIGH)
- Account disabled but declaration says active → **DISABLED_BUT_ACTIVE** (HIGH)
- Account in AD but not declared → **ORPHAN_IN_AD** (MEDIUM)

Exit code 2 when drift detected (matches Terraform convention).

---

## 6. Terraform Module: `entra-service-principal` (unchanged from v1)

Uses `hashicorp/azuread` provider. See v1 doc `03-terraform-modules.md` Section 5 for full HCL.

---

## 7. Terraform Module: `aws-iam-role` (unchanged from v1)

Uses `hashicorp/aws` provider. See v1 doc `03-terraform-modules.md` Section 6 for full HCL.

---

## 8. Terraform Module: `database-account` (unchanged from v1)

Uses `cyrilgdn/postgresql` and `betr-io/mssql` providers. See v1 doc `03-terraform-modules.md` Section 7 for full HCL.

---

## 9. GitLab CI/CD Pipeline (v2)

```yaml
# .gitlab-ci.yml
stages:
  - validate
  - plan
  - apply
  - drift-detect

variables:
  TF_LOG: "WARN"

# ══════════════════════════════════════════════════════════════════
# AD PROVISIONING — PowerShell (domain-joined runner)
# ══════════════════════════════════════════════════════════════════

.powershell-base:
  tags: [domain-joined-runner]
  before_script:
    - Import-Module ActiveDirectory
    - . execution/ad/config.ps1
    - . execution/ad/logging.ps1

validate-ad-declarations:
  extends: .powershell-base
  stage: validate
  script:
    - pwsh -File execution/ad/Validate-AccountDeclaration.ps1
        -Path "accounts/ad/"
    - pwsh -File execution/ad/Validate-AccountDeclaration.ps1
        -Path "accounts/gmsa/"
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: ["accounts/ad/**", "accounts/gmsa/**", "execution/ad/**"]

plan-ad:
  extends: .powershell-base
  stage: plan
  script:
    - pwsh -File execution/ad/New-ServiceAccount.ps1
        -Name "$ACCOUNT_NAME" -Environment "$ENV"
        -JiraTicket "$JIRA_TICKET" -TechnicalOwner "$OWNER"
        -WhatIf
  rules:
    - if: $PIPELINE_TYPE == "powershell-ad" && $ACCOUNT_TYPE == "AD SA"

plan-gmsa:
  extends: .powershell-base
  stage: plan
  script:
    - pwsh -File execution/ad/New-GroupManagedSA.ps1
        -Name "$ACCOUNT_NAME" -Environment "$ENV"
        -JiraTicket "$JIRA_TICKET" -TechnicalOwner "$OWNER"
        -MemberServers ($MEMBER_SERVERS -split ",")
        -WhatIf
  rules:
    - if: $PIPELINE_TYPE == "powershell-ad" && $ACCOUNT_TYPE == "gMSA"

apply-ad:
  extends: .powershell-base
  stage: apply
  script:
    - pwsh -File execution/ad/New-ServiceAccount.ps1
        -Name "$ACCOUNT_NAME" -Environment "$ENV"
        -OUPath "$OU_PATH" -JiraTicket "$JIRA_TICKET"
        -TechnicalOwner "$OWNER"
        -Groups ($GROUPS -split ",")
        -DelineaFolderId "$DELINEA_FOLDER"
  rules:
    - if: $CI_COMMIT_BRANCH == "main" && $PIPELINE_TYPE == "powershell-ad" && $ACCOUNT_TYPE == "AD SA"
  when: manual

apply-gmsa:
  extends: .powershell-base
  stage: apply
  script:
    - pwsh -File execution/ad/New-GroupManagedSA.ps1
        -Name "$ACCOUNT_NAME" -Environment "$ENV"
        -JiraTicket "$JIRA_TICKET" -TechnicalOwner "$OWNER"
        -MemberServers ($MEMBER_SERVERS -split ",")
        -SPNs ($SPNS -split ",")
  rules:
    - if: $CI_COMMIT_BRANCH == "main" && $PIPELINE_TYPE == "powershell-ad" && $ACCOUNT_TYPE == "gMSA"
  when: manual

drift-detect-ad:
  extends: .powershell-base
  stage: drift-detect
  script:
    - pwsh -File execution/ad/Compare-ADState.ps1
        -DeclarationPath "accounts/ad/"
        -ReportPath ".tmp/ad-drift-report.json"
        -CreateJiraAlert
    - pwsh -File execution/ad/Compare-ADState.ps1
        -DeclarationPath "accounts/gmsa/"
        -ReportPath ".tmp/gmsa-drift-report.json"
        -CreateJiraAlert
  artifacts:
    paths: [".tmp/ad-drift-report.json", ".tmp/gmsa-drift-report.json"]
    expire_in: 30 days
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  allow_failure: false

# ══════════════════════════════════════════════════════════════════
# TERRAFORM PROVISIONING — Entra/AWS/DB (unchanged from v1)
# ══════════════════════════════════════════════════════════════════

.terraform-base:
  image: registry.gitlab.bank.internal/platform/terraform:1.7-delinea
  before_script:
    - terraform init -backend-config="environments/${ENV}/backend.tf"

validate-terraform:
  extends: .terraform-base
  stage: validate
  script:
    - terraform validate
    - python3 scripts/validate-naming.py accounts/
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: ["accounts/entra-sp/**", "accounts/aws-roles/**", "accounts/databases/**", "modules/**"]

plan-terraform:
  extends: .terraform-base
  stage: plan
  script:
    - terraform plan -out=tfplan.binary
    - terraform show -json tfplan.binary > tfplan.json
  artifacts:
    paths: [tfplan.binary, tfplan.json]
    expire_in: 7 days
  rules:
    - if: $PIPELINE_TYPE == "terraform"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: ["accounts/entra-sp/**", "accounts/aws-roles/**", "accounts/databases/**"]

apply-terraform:
  extends: .terraform-base
  stage: apply
  script:
    - terraform apply -auto-approve tfplan.binary
    - echo "Apply complete - update Jira ticket ${JIRA_TICKET}"
  environment:
    name: $ENV
  rules:
    - if: $CI_COMMIT_BRANCH == "main" && $PIPELINE_TYPE == "terraform"
  when: manual

drift-detect-terraform:
  extends: .terraform-base
  stage: drift-detect
  script:
    - bash scripts/drift-detect.sh
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  allow_failure: false
```

---

## 10. Drift Detection Summary (v2)

| Scope | Tool | Schedule | Alert |
|---|---|---|---|
| AD Service Accounts | `Compare-ADState.ps1` | Nightly (GitLab CI schedule) | Jira "Drift Alert" issue |
| gMSA accounts | `Compare-ADState.ps1` | Nightly | Jira "Drift Alert" issue |
| Entra Service Principals | `terraform plan` | Nightly | Jira "Drift Alert" issue (via webhook) |
| AWS IAM Roles | `terraform plan` | Nightly | Jira "Drift Alert" issue |
| Database Accounts | `terraform plan` | Nightly | Jira "Drift Alert" issue |
