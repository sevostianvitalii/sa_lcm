# Service Account Lifecycle Management (SACM)

Complete lifecycle management system for all service account types across a hybrid banking infrastructure (AD, Entra ID, AWS, Linux, Databases).

## Architecture

**Hybrid provisioning model:**

| Identity Plane | Provisioning Tool | Declaration Format |
|---|---|---|
| AD on-prem (SA, gMSA) | **PowerShell** (RSAT ActiveDirectory) | JSON (`accounts/ad/`, `accounts/gmsa/`) |
| Entra ID (SP, MI) | **Terraform** (`hashicorp/azuread`) | HCL (`.tf` files) |
| AWS (IAM Roles) | **Terraform** (`hashicorp/aws`) | HCL (`.tf` files) |
| Database (SQL, PostgreSQL) | **Terraform** | HCL (`.tf` files) |

**Orchestration:** Jira Cloud + JSM → GitLab CI → PowerShell or Terraform → Delinea/AWS SM

## Repository Structure

```
├── execution/ad/               ← PowerShell scripts for AD provisioning
│   ├── config.ps1              ← Shared config (domain, OUs, Delinea)
│   ├── logging.ps1             ← Structured JSON audit logging
│   ├── New-ServiceAccount.ps1  ← Create AD service account
│   ├── Remove-ServiceAccount.ps1 ← Decommission AD service account
│   ├── New-GroupManagedSA.ps1  ← Create gMSA
│   ├── Compare-ADState.ps1    ← Drift detection (replaces terraform plan for AD)
│   └── Validate-AccountDeclaration.ps1 ← CI validation for JSON declarations
│
├── accounts/                   ← Declarative account definitions
│   ├── ad/                     ← JSON declarations for AD SAs + schema
│   ├── gmsa/                   ← JSON declarations for gMSAs + schema
│   ├── entra-sp/               ← Terraform .tf for Entra SPs
│   ├── aws-roles/              ← Terraform .tf for AWS IAM Roles
│   └── databases/              ← Terraform .tf for DB accounts
│
├── modules/                    ← Terraform modules (Entra/AWS/DB)
├── providers/                  ← Terraform provider version pins
├── environments/               ← Per-env backend config
└── docs/                       ← Documentation (v1 + v2)
```

## Documentation

### v2 (Current — Hybrid PowerShell + Terraform)

- [Master Plan v2](./docs/v2/01-master-plan-v2.md) — Architecture, Phase 0 runner setup, phased rollout
- [Lifecycle Stages v2](./docs/v2/02-lifecycle-stages-v2.md) — State machine and SLAs for all 9 account types
- [Provisioning Modules v2](./docs/v2/03-provisioning-modules-v2.md) — PowerShell + Terraform modules, CI/CD pipeline, drift detection
- [Jira Schema v2](./docs/v2/04-jira-schema-v2.md) — JSM portal, routing automations, webhook security
- [Secrets & Rotation v2](./docs/v2/05-secrets-rotation-v2.md) — Delinea + AWS SM integration
- [Policy & SOP v2](./docs/v2/06-policy-sop-v2.md) — Governance policy, RACI, and updated standard operating procedures

### v1 (Original — Terraform-only design)

- [Master Plan](./docs/01-master-plan.md)
- [Lifecycle Stages](./docs/02-lifecycle-stages.md)
- [Terraform Modules](./docs/03-terraform-modules.md)
- [Jira Schema](./docs/04-jira-schema.md)
- [Secrets & Rotation](./docs/05-secrets-rotation.md)
- [Policy & SOP](./docs/06-policy-sop.md)

## Design Decisions

**Why PowerShell for AD?** The `hashicorp/ad` Terraform provider is experimental, community-maintained, and hasn't been updated in 2+ years. It relies on WinRM which is fragile in enterprise networks. Native PowerShell with RSAT is the standard enterprise approach for AD management.

**Why keep Terraform for Entra ID?** The `hashicorp/azuread` provider is actively maintained by HashiCorp, production-grade, and provides built-in state management and drift detection. Replacing it would be unnecessary churn.

## License

Internal / Restricted
