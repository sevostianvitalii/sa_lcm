# Policy & SOP: Service Account Lifecycle Management

**Document ID:** IS-POL-007  
**Owner:** Information Security — IAM Operations  
**Version:** 1.0  
**Effective Date:** 2026-03-01  
**Review Cycle:** Annual  
**Classification:** Internal — Restricted

---

## 1. Policy Statement

The Bank shall maintain full lifecycle control over all service accounts across hybrid infrastructure (on-premises Active Directory, Entra ID, AWS, Linux and application layers). Every service account shall have a named owner, documented purpose, minimum required privileges, automated credential rotation, and be subject to periodic revalidation.

No service account shall exist without a corresponding approved record in the Service Account Lifecycle Management (SACM) Jira project and a Terraform declaration in the bank's service-accounts GitLab repository.

---

## 2. Scope

**In scope:** All non-human accounts used for automated processes, services, integrations, or scheduled jobs within the bank's environment, including:
- Active Directory service accounts and gMSAs
- Microsoft Entra ID Service Principals and Managed Identities
- AWS IAM Roles and IAM Users (service purpose)
- Linux operating system service accounts
- Database service accounts (SQL Server, PostgreSQL, Oracle, MongoDB)
- API keys, OAuth clients, and service tokens

**Out of scope:** Human user accounts, shared team accounts (prohibited), named administrator accounts (covered by PAM policy IS-POL-005).

**Applicability:** All IT staff, application developers, DevOps engineers, third-party vendors with administrative access, and any system that creates or consumes service accounts.

---

## 3. Definitions

| Term | Definition |
|---|---|
| **Service Account** | Non-interactive account used by an application, service, or script |
| **Technical Owner** | Named individual responsible for the account's technical operation |
| **Business Owner** | Manager accountable for the business process the account supports |
| **Privileged Service Account** | Service account with elevated rights (see Section 6.2) |
| **Delinea** | Bank's Privileged Access Management platform (Secret Server + DSV) |
| **SACM** | Service Account Lifecycle Management — Jira project and process |
| **Terraform State** | GitLab-managed infrastructure state representing account declarations |

---

## 4. Roles & Responsibilities (RACI)

| Activity | Requestor | Line Manager | InfoSec / IAM Ops | DBA / Cloud Ops | Business Owner | CISO |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Submit account request | **R** | I | I | — | A | — |
| Level-1 approval | C | **A/R** | I | — | C | — |
| Security review (privileged) | I | I | **A/R** | I | I | C |
| Terraform provisioning | — | — | **R** | C | — | — |
| Credential management / Delinea | — | — | **A/R** | C | — | — |
| Annual review completion | **R** | I | I | C | **A** | — |
| Decommission execution | I | I | **R** | C | A | — |
| Emergency break-glass | R | I | **A/R** | C | I | **A** |
| Policy ownership | — | — | **A** | — | — | R |
| Audit log review (quarterly) | — | — | **R** | — | — | A |

**R** = Responsible, **A** = Accountable, **C** = Consulted, **I** = Informed

---

## 5. Standards

### 5.1 Naming Conventions

| Account Type | Format | Example |
|---|---|---|
| AD Service Account | `svc-{appname}-{env}` | `svc-billing-prod` |
| gMSA | `gmsa-{appname}-{env}` | `gmsa-sqlreport-prod` |
| Entra Service Principal | `sp-{appname}-{env}` | `sp-paymentapi-prod` |
| Entra Managed Identity | `mi-{appname}-{env}` | `mi-reportgen-prod` |
| AWS IAM Role | `role-{appname}-{service}-{env}` | `role-billing-lambda-prod` |
| Linux Service Account | `svc_{appname}` | `svc_billing` |
| Database Account | `svc_{appname}_{db}` | `svc_billing_sqlprod` |

### 5.2 Privilege Classification

| Level | Criteria | Examples |
|---|---|---|
| **Standard** | Read/write to specific resources; no admin rights | DB read access, S3 bucket read |
| **Elevated** | Write to multiple systems; service restart rights; limited admin | IIS application pool, DBA schema owner |
| **Privileged** | Domain admin equivalent; global cloud admin; cross-account assume role; schema DDL | Domain Admin group member, AdministratorAccess AWS policy, Entra Global Admin role |

Privileged accounts require Security Team review and CISO notification.

### 5.3 Credential Policies

| Credential Type | Maximum Age | Rotation Method | Storage |
|---|---|---|---|
| AD service account password | 30 days | Delinea auto-rotate | Delinea Secret Server |
| gMSA password | 30 days | Active Directory native | AD KDS (never exposed) |
| Entra client secret | 90 days | Delinea → Graph API | Delinea DSV |
| Entra certificate | 1 year | PKI renewal | Delinea DSV |
| AWS IAM access key | 30 days | AWS SM Lambda | AWS Secrets Manager |
| Database password | 30 days | Delinea heartbeat | Delinea Secret Server |
| API key / token | 1 year maximum | Assisted/manual | Delinea DSV |
| SSH private key | 90 days | Delinea | Delinea Secret Server |

**Prohibited:** Hardcoded credentials in any code, configuration file, CI/CD variable (in plain text), script, or documentation. Violation = immediate security incident.

---

## 6. Standard Operating Procedures

### SOP-01: New Service Account Provisioning

**Trigger:** Application team requires a new service account.  
**SLA:** 2 business days (standard), 5 business days (privileged).

```
Step 1 — Assess Need
  □ Confirm a service account is actually required (cannot use Managed Identity / IAM Role?)
  □ Determine the minimum required permissions (principle of least privilege)
  □ Identify Technical Owner (must be active employee, cannot be a team mailbox)
  □ Identify Business Owner (accountable manager)
  □ Determine environment (prod / staging / dev)

Step 2 — Submit Request in Jira (SACM project)
  □ Create issue type: "Service Account Request"
  □ Fill all mandatory fields (account type, environment, justification, owner, permissions)
  □ Set privilege level (Standard / Elevated / Privileged)
  □ Attach architecture diagram or service description if complex
  □ Submit → status moves to "Pending Approval"

Step 3 — Level-1 Approval (Line Manager / System Owner)
  □ Verify: business need is genuine and documented
  □ Verify: requestor is authorized to request for this system
  □ Verify: owner is correct and aware
  □ Approve → if privileged: routes to Security Review
             if standard: routes to Provisioning

Step 4 — Security Review (Privileged accounts only)
  □ InfoSec reviews: privilege justification, non-privileged alternative possible?
  □ InfoSec reviews: time-bound or permanent need?
  □ InfoSec completes risk assessment comment on Jira ticket
  □ Approve or Reject with documented reason

Step 5 — Terraform Declaration (IAM Operations)
  □ Create .tf file in accounts/{type}/{account-name}-{env}.tf
  □ Module parameters match Jira ticket details
  □ Add Jira ticket reference to description and jira_ticket variable
  □ Open Merge Request → assign 2 reviewers (peer + tech lead)
  □ MR approved → merge to main

Step 6 — Automated Provisioning (GitLab Pipeline)
  □ Pipeline triggered on merge to main
  □ Terraform plan → Terraform apply
  □ Delinea secret created automatically by Terraform
  □ Pipeline posts result back to Jira webhook
  □ Jira ticket transitions to "Active" automatically
  □ Owner notified by email with account name (NOT credentials)

Step 7 — Credential Delivery
  □ Technical Owner retrieves credentials from Delinea (checkout)
  □ Credentials never sent by email, Teams, or any messaging platform
  □ First checkout logged in Delinea audit trail
```

---

### SOP-02: Periodic Review (Annual / Quarterly)

**Trigger:** Jira Automation creates "Service Account Review" ticket on schedule.  
**SLA:** 14 days response (7 days for privileged accounts).

```
Step 1 — Notification
  □ Technical Owner receives email + Jira assignment
  □ Business Owner CC'd on notification

Step 2 — Owner Assessment (Technical Owner completes)
  □ Is the account still in use? (check application logs / Delinea checkout log)
  □ Are the permissions still required and appropriate?
  □ Are the member servers / target systems still correct?
  □ Has the Technical Owner changed? (update if necessary)
  □ Has the Business Owner changed? (update if necessary)

Step 3 — Decision

  RENEW (account still needed, no changes):
  □ Set "Review Decision" = Renew
  □ Check "Owner Confirmation" checkbox
  □ Transition review ticket to Done
  □ Parent ticket → next review date reset (+365 or +90 days)

  MODIFY (changes required):
  □ Set "Review Decision" = Modify
  □ Describe required changes in comments
  □ Open new Terraform MR with changes
  □ Follow SOP-01 Step 5-6 for re-approval if privilege change
  □ Transition review ticket to Done after changes applied

  DECOMMISSION (account no longer needed):
  □ Set "Review Decision" = Decommission
  □ Follow SOP-03 (Decommissioning)

Step 4 — No Response (Grace Period Exceeded)
  □ Jira Automation triggers after 14 days (7 for privileged)
  □ Account automatically decommissioned (SOP-03 automated path)
  □ Technical Owner and Business Owner notified of forced decommission
```

---

### SOP-03: Decommissioning

**Trigger:** Owner decision in review, application retirement, employee departure, or automated grace-period expiry.  
**SLA:** 5 business days for planned; immediate for security-triggered.

```
Step 1 — Initiate Decommission
  □ Update Jira ticket "Review Decision" = Decommission (or create Decommission issue)
  □ Confirm with consuming applications that account is no longer needed
  □ Identify all systems using the account (check Delinea checkout log + app configs)

Step 2 — Notify Consumers
  □ At least 5 business days notice to application teams (planned decommissions)
  □ Application teams confirm account is removed from configurations
  □ Zero for security-triggered decommissions

Step 3 — Disable Account (Day of Decommission)
  □ Terraform: set account to disabled state (Terraform apply disable flag)
  □ Monitor for 24 hours — any authentication failures? (check identity logs)
  □ If failures detected: pause → investigate → fix consuming app first

Step 4 — Delete Account (After 30-day Retention for AD; Immediate for Cloud)
  □ AD accounts: Move to "Disabled_SVC" OU → delete after 30 days
  □ Entra SP: Delete application registration
  □ AWS IAM Role: delete_role after policy detachment
  □ Linux SA: userdel -r svc_{name}
  □ DB accounts: DROP USER / DROP LOGIN
  □ API keys: Revoke at source + update consuming systems

Step 5 — Secret Cleanup
  □ Delinea: delete secret and revoke all active checkouts
  □ AWS SM: delete secret (with recovery window = 7 days)
  □ Verify no active sessions using the credential (Delinea session log)

Step 6 — Terraform Cleanup
  □ Delete .tf declaration file from accounts/ directory
  □ Run terraform destroy for specific resource OR terraform apply (deletion detected)
  □ Verify resource removed from Terraform state

Step 7 — Close Jira Ticket
  □ Transition to "Decommissioned"
  □ Add final comment with confirmation of all cleanup steps
  □ Retain Jira ticket for minimum 5 years (audit retention)
```

---

### SOP-04: Emergency Break-Glass

**Trigger:** Critical incident requiring immediate service account access without standard approval cycle.  
**Authority:** CISO, Head of Infrastructure, or delegated deputy.

```
Step 1 — Create Emergency Issue in Jira (< 5 minutes)
  □ Issue type: "Emergency Break-Glass"
  □ Fields: incident reference, justification, access duration (max 24h)
  □ Notify CISO immediately (phone if outside hours)

Step 2 — Emergency Access (CISO verbal approval → retroactive documented)
  □ CISO provides verbal approval
  □ IAM Operations configures emergency access in Delinea (time-limited checkout)
  □ All actions during emergency access logged (Delinea session recording if applicable)

Step 3 — Post-Emergency (within 24 hours)
  □ Access revoked (forced checkout return in Delinea)
  □ Emergency account password force-rotated
  □ CISO provides written approval in Jira ticket
  □ Audit log exported and attached to ticket
  □ Session recording linked to ticket

Step 4 — Post-Incident Review
  □ IAM Operations reviews what was accessed and why
  □ Security reviews for any misuse
  □ SOP or control gap identified → Jira improvement ticket created
  □ CISO signs off on incident review
```

---

## 7. Exception Process

Any deviation from this policy requires:

1. **Submitter:** Document the business reason for exception
2. **Line Manager approval:** Written approval via Jira comment
3. **InfoSec approval:** Risk acceptance documented in Jira
4. **CISO sign-off** for exceptions to: privilege classification, credential age limits over 2x standard, or no-rotation exceptions
5. **Annual review:** All exceptions re-reviewed annually
6. **Time-bound:** Exceptions are granted for maximum 1 year; must be renewed or resolved

**Known exception categories:**
- Legacy application cannot support credential rotation → documented risk acceptance + mitigation required
- gMSA not applicable (OS version too old) → AD SA with Delinea rotation + compensating controls
- Third-party SaaS API key with no rotation API → document + maximum 1-year lifecycle enforced

---

## 8. Compliance & Audit

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
| NIST SP 800-53 AC-2 — Account Management | Approval + scheduled annual/quarterly review | Jira |
| NIST SP 800-53 IA-5 — Authenticator Management | Delinea/AWS SM scheduled password rotation | Delinea / CloudWatch |
| NIST CSF PR.AA-1 / PR.AA-3 — Identities/Auth | Terraform declarative identity management | GitLab MR + Terraform state |

**Audit review schedule:**
- **Quarterly:** IAM Operations reviews Delinea rotation failures + SACM drift alerts
- **Semi-annual:** InfoSec reviews all Privileged accounts
- **Annual:** Full SACM report to CISO (accounts created, reviewed, decommissioned, exceptions)
- **Annual external:** Evidence package prepared for external auditors (PCI QSA, ISO auditor)

---

## 9. Policy Violations & Enforcement

| Violation | Severity | Response |
|---|---|---|
| Service account without SACM ticket | High | Account suspended within 24h; owner notified |
| Hardcoded credential found in code | Critical | Immediate credential rotation; security review; disciplinary action |
| Credential shared via email/Teams | High | Immediate rotation; security awareness training |
| Account used beyond approved scope | High | Account suspended; investigation opened |
| Review not completed within SLA | Medium | Manager notified; account suspended after grace period |
| Exception used without approval | Critical | Account suspended; disciplinary action |

---

## 10. Document History

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 2026-03-01 | IAM Operations | Initial release |
| — | — | — | — |

**Next scheduled review:** 2027-03-01  
**Document owner:** Head of IAM Operations  
**Approved by:** CISO
