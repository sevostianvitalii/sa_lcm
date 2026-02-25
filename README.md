# Service Account Lifecycle Management (SACM)

Complete lifecycle management system for all service account types across a hybrid banking infrastructure (AD, Entra ID, AWS, Linux, Databases).

## Quick Start

This repository contains the architecture, process definitions, and infrastructure-as-code design for managing service accounts automatically via Jira, GitLab CI, Terraform, and Delinea Secret Server/DSV.

Review the documentation in the `docs/` folder to get started.

## Documentation

- [Master Plan](./docs/01-master-plan.md) — Architecture diagram, component roles, and phased rollout.
- [Lifecycle Stages](./docs/02-lifecycle-stages.md) — State machine and SLAs for all 9 account types.
- [Terraform Modules](./docs/03-terraform-modules.md) — Repository structure, module examples, and CI/CD pipelines.
- [Jira Schema](./docs/04-jira-schema.md) — Issue types, 15+ custom fields, full workflow, and automation rules.
- [Secrets & Rotation](./docs/05-secrets-rotation.md) — Password management via Delinea and AWS Secrets Manager.
- [Policy & SOP](./docs/06-policy-sop.md) — Governance policy, RACI matrix, and standard operating procedures.

## License

Internal / Restricted
