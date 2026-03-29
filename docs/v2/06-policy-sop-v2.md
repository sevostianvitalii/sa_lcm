# Policy & SOP v2: Service Account Lifecycle Management

**Document ID:** IS-POL-007  
**Owner:** Information Security — IAM Operations  
**Version:** 2.0  
**Effective Date:** 2026-04-01  
**Review Cycle:** Annual  
**Classification:** Internal — Restricted

> **v2 changes:** Updated SOP-01 to reflect dual provisioning model (PowerShell for AD, Terraform for cloud/DB). Updated policy statement to include JSON declarations. Added JSM portal reference. Updated NIST/compliance mapping.

---

## 1. Policy Statement (v2)

The Bank shall maintain full lifecycle control over all service accounts across hybrid infrastructure (on-premises Active Directory, Entra ID, AWS, Linux and application layers). Every service account shall have a named owner, documented purpose, minimum required privileges, automated credential rotation, and be subject to periodic revalidation.

No service account shall exist without a corresponding approved record in the Service Account Lifecycle Management (SACM) Jira project and either:
- A **Terraform declaration** (.tf file) in the service-accounts GitLab repository (for Entra ID, AWS, database, and application accounts), OR
- A **JSON declaration** (.json file) in the service-accounts GitLab repository (for on-prem AD and gMSA accounts)

---

## 2. Scope

_(Unchanged from v1 — see original `06-policy-sop.md`)_

---

## 3. Definitions (v2)

| Term | Definition |
|---|---|
| **Service Account** | Non-interactive account used by an application, service, or script |
| **Technical Owner** | Named individual responsible for the account's technical operation |
| **Business Owner** | Manager accountable for the business process the account supports |
| **Privileged Service Account** | Service account with elevated rights (see Section 6.2) |
| **Delinea** | Bank's Privileged Access Management platform (Secret Server + DSV) |
| **SACM** | Service Account Lifecycle Management — Jira project and process |
| **Terraform State** | GitLab-managed infrastructure state for cloud/DB accounts |
| **JSON Declaration** | Git-managed JSON file for AD/gMSA accounts _(v2 new)_ |
| **JSM Portal** | Jira Service Management self-service request form _(v2 new)_ |

---

## 4. Roles & Responsibilities (RACI)

_(Unchanged from v1 — see original `06-policy-sop.md`)_

---

## 5. Standards

_(Sections 5.1 Naming Conventions, 5.2 Privilege Classification, 5.3 Credential Policies — unchanged from v1)_

---

## 6. Standard Operating Procedures (v2)

### SOP-01: New Service Account Provisioning (v2)

**Trigger:** Application team requires a new service account.  
**SLA:** 2 business days (standard), 5 business days (privileged).

```
Step 1 — Assess Need
  □ Confirm a service account is actually required
    (cannot use Managed Identity / IAM Role?)
  □ Determine the minimum required permissions (principle of least privilege)
  □ Identify Technical Owner (must be active employee, cannot be a team mailbox)
  □ Identify Business Owner (accountable manager)
  □ Determine environment (prod / staging / dev)

Step 2 — Submit Request
  □ OPTION A: Via JSM Self-Service Portal (recommended for non-IAM staff)
    - Navigate to IAM Self-Service Portal
    - Select "New Service Account" request type
    - Fill guided form (account type, environment, justification, etc.)
    - Submit → creates SACM ticket automatically
  □ OPTION B: Via Jira directly (for IAM Operations team)
    - Create issue type: "Service Account Request" in SACM project
    - Fill all mandatory fields
  □ Status moves to "Pending Approval"

Step 3 — Level-1 Approval (Line Manager / System Owner)
  □ Verify: business need is genuine and documented
  □ Verify: requestor is authorized to request for this system
  □ Verify: owner is correct and aware
  □ Approve → if privileged: routes to Security Review
              if standard: routes to Provisioning

Step 4 — Security Review (Privileged accounts only)
  □ InfoSec reviews: privilege justification, non-privileged alternative?
  □ InfoSec reviews: time-bound or permanent need?
  □ InfoSec completes risk assessment comment on Jira ticket
  □ Approve or Reject with documented reason

Step 5 — Account Declaration (IAM Operations)

  FOR AD SERVICE ACCOUNTS AND gMSA:
  □ Create .json file in accounts/ad/ or accounts/gmsa/
  □ Follow JSON schema (accounts/ad/schema.json or accounts/gmsa/schema.json)
  □ Include all required fields: name, environment, type, ou_path/member_servers,
    jira_ticket, technical_owner, status
  □ Open Merge Request → assign 2 reviewers (peer + tech lead)
  □ CI validation stage runs Validate-AccountDeclaration.ps1 automatically
  □ MR approved → merge to main

  FOR ENTRA, AWS, DATABASE, AND APPLICATION ACCOUNTS:
  □ Create .tf file in accounts/{type}/{account-name}-{env}.tf
  □ Module parameters match Jira ticket details
  □ Add Jira ticket reference to description and jira_ticket variable
  □ Open Merge Request → assign 2 reviewers (peer + tech lead)
  □ CI validation runs terraform validate automatically
  □ MR approved → merge to main

Step 6 — Automated Provisioning (GitLab Pipeline)

  FOR AD/gMSA (PowerShell pipeline):
  □ Pipeline triggered on merge to main (or via Jira webhook)
  □ PowerShell dry-run (WhatIf) → manual approval → PowerShell execute
  □ New-ServiceAccount.ps1 or New-GroupManagedSA.ps1 runs on domain-joined runner
  □ Delinea secret registered via REST API (AD SA only; gMSA has no secret)
  □ Pipeline posts result back to Jira webhook
  □ Jira ticket transitions to "Active" automatically
  □ Owner notified by email with account name (NOT credentials)

  FOR ENTRA/AWS/DB (Terraform pipeline):
  □ Pipeline triggered on merge to main (or via Jira webhook)
  □ Terraform plan → manual approval → Terraform apply
  □ Delinea secret created via Terraform delinea provider
  □ Pipeline posts result back to Jira webhook
  □ Jira ticket transitions to "Active" automatically

Step 7 — Credential Delivery
  □ Technical Owner retrieves credentials from Delinea (checkout)
  □ Credentials never sent by email, Teams, or any messaging platform
  □ First checkout logged in Delinea audit trail
```

---

### SOP-02: Periodic Review (Annual / Quarterly)

_(Unchanged from v1 — see original `06-policy-sop.md`)_

---

### SOP-03: Decommissioning (v2)

**Trigger:** Owner decision in review, application retirement, employee departure, or automated grace-period expiry.  
**SLA:** 5 business days for planned; immediate for security-triggered.

```
Step 1 — Initiate Decommission
  □ Update Jira ticket "Review Decision" = Decommission
  □ Confirm with consuming applications that account is no longer needed
  □ Identify all systems using the account

Step 2 — Notify Consumers
  □ At least 5 business days notice (planned decommissions)
  □ Zero for security-triggered decommissions

Step 3 — Disable Account (Day of Decommission)

  FOR AD/gMSA:
  □ execution/ad/Remove-ServiceAccount.ps1 via GitLab pipeline:
    - Disable-ADAccount
    - Remove all group memberships
    - Move to Disabled_SVC OU
    - Delinea: disable auto-change, deactivate secret
  □ Monitor for 24 hours (check identity logs for auth failures)

  FOR ENTRA/AWS/DB:
  □ Terraform: set account to disabled state, terraform apply
  □ Monitor for 24 hours

Step 4 — Delete Account (retention period)
  □ AD accounts: 30-day retention in Disabled_SVC OU → then delete
  □ Entra SP: delete application registration (immediate or after retention)
  □ AWS IAM Role: delete_role after policy detachment
  □ DB accounts: DROP USER / DROP LOGIN

Step 5 — Declaration Cleanup
  □ AD/gMSA: Update JSON declaration status to "decommissioned"
    (keep file for audit history — do not delete)
  □ Entra/AWS/DB: Delete .tf file from accounts/ directory
    terraform apply detects deletion

Step 6 — Secret Cleanup
  □ Delinea: delete secret and revoke active checkouts
  □ AWS SM: delete secret (with 7-day recovery window)

Step 7 — Close Jira Ticket
  □ Transition to "Decommissioned"
  □ Add final comment with confirmation of all cleanup steps
  □ Retain Jira ticket for minimum 5 years (audit retention)
```

---

### SOP-04: Emergency Break-Glass

_(Unchanged from v1 — see original `06-policy-sop.md`)_

---

## 7. Exception Process

_(Unchanged from v1)_

---

## 8. Compliance & Audit (v2)

| Requirement | How Met | Evidence |
|---|---|---|
| PCI-DSS 8.6.1 — Manage service accounts | Full SACM lifecycle + Jira audit | Jira + Git history |
| PCI-DSS 8.3.9 — Rotate credentials ≤ 90 days | Delinea automated rotation | Delinea audit log |
| SOX ITGC CC6.1 — Logical access | Jira approval trail | Jira + SACM reports |
| SOX ITGC CC6.2 / CC6.3 — New access, modification | GitLab MR + Jira approval | MR history |
| ISO 27001 A.9.2 — User access management | Provisioning + review SOP | Jira |
| ISO 27001 A.9.4 — Privileged access | Security review gate | Jira |
| ISO 27001 A.12.4 — Logging and monitoring | Delinea + GitLab + Jira | Audit exports |
| GDPR — Access minimization | Least-privilege standard | Jira field: Permissions Requested |
| NIST SP 800-53 AC-2 — Account Management | Approval + scheduled review | Jira |
| NIST SP 800-53 IA-5 — Authenticator Management | Delinea/AWS SM rotation | Delinea / CloudWatch |
| NIST CSF PR.AA-1 / PR.AA-3 — Identities/Auth | Terraform + PowerShell declarative management | GitLab MR + TF state + JSON declarations |

---

## 9. Policy Violations & Enforcement

_(Unchanged from v1)_

---

## 10. Document History

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 2026-03-01 | IAM Operations | Initial release |
| 2.0 | 2026-04-01 | IAM Operations | Replaced hashicorp/ad with PowerShell RSAT. Added JSM portal. Updated SOPs for dual provisioning model. Added SLA escalation. |

**Next scheduled review:** 2027-04-01  
**Document owner:** Head of IAM Operations  
**Approved by:** CISO
