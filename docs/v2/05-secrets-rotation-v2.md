# Secrets & Rotation Design v2 — Delinea + AWS Secrets Manager

> **v2 changes:** AD service account initial secret registration now uses PowerShell REST API calls to Delinea (replaces Terraform `delinea_secret` resource for AD accounts). All other rotation mechanisms unchanged.

---

## 1. Secret Management Decision Matrix

| Account Type | Secret Exists? | Manager | Rotation Method | Rotation Interval | Registration (v2) |
|---|:---:|---|---|---|---|
| AD Service Account | ✅ Password | **Delinea PAM/DSV** | Heartbeat auto-rotate | 30 days | **PowerShell REST API** |
| gMSA | ❌ (AD-managed) | AD KDS Root Key | Native AD | 30 days | N/A |
| Entra SP (secret) | ✅ Client Secret | **Delinea DSV** | Delinea → Entra ID API | 90 days | Terraform `delinea_secret` |
| Entra SP (cert) | ✅ Private Key | **Delinea DSV** | PKI renewal + Terraform | 1 year | Terraform `delinea_secret` |
| Entra Managed Identity | ❌ | Azure platform | N/A | N/A | N/A |
| AWS IAM Role | ❌ | STS token | N/A (assumed) | N/A | N/A |
| AWS IAM User (legacy) | ✅ Access Key | **AWS SM** | Lambda rotation function | 30 days | Terraform `aws_secretsmanager_secret` |
| Linux SA (no sudo) | ❌ | N/A | N/A | N/A | N/A |
| Linux SA (SSH key) | ✅ SSH Key | **Delinea PAM** | Delinea SSH key rotate | 90 days | Terraform `delinea_secret` |
| Database Account | ✅ Password | **Delinea PAM** | Heartbeat auto-rotate | 30 days | Terraform `delinea_secret` |
| API Key / Token | ✅ Token | **Delinea DSV** | Assisted/manual trigger | 90 days max | Terraform `delinea_secret` |

---

## 2. Delinea Architecture

_(Unchanged from v1 — see original `05-secrets-rotation.md` for products, folder structure, and secret templates)_

---

## 3. Delinea Secret Server — AD Account Registration (v2 UPDATED)

### v2 Change: Registration via PowerShell REST API

In v1, the initial AD account password was registered in Delinea using the Terraform `delinea_secret` resource. In v2, since AD provisioning uses PowerShell, the registration is done via Delinea's REST API within the `New-ServiceAccount.ps1` script.

### How Registration Works (v2)

```
[New-ServiceAccount.ps1]
    │
    ├─ Generate 32-char password (New-SecurePassword)
    ├─ Create AD user (New-ADUser)
    │
    ├─ Authenticate to Delinea REST API (client_credentials flow)
    │   POST /oauth2/token
    │   → access_token
    │
    ├─ Create secret in Delinea
    │   POST /api/v1/secrets
    │   Body:
    │     name: "svc-billing-prod"
    │     secretTemplateId: 6002  (AD Service Account + Heartbeat)
    │     folderId: 1042          (Prod / AD Service Accounts)
    │     items:
    │       - Username: svc-billing-prod
    │       - Password: {generated}
    │       - Domain: bank.local
    │       - Notes: description + ticket ref
    │     autoChangeEnabled: true
    │     enableHeartbeat: true
    │
    └─ Zero plain-text password from memory
```

### Post-Registration: Rotation (unchanged)

Once registered, Delinea handles all subsequent rotations identically to v1:

```
[Delinea Heartbeat - Nightly]
    │
    ├─ Connect to AD DC
    ├─ Test bind with stored password
    ├─ If FAIL → trigger auto-change
    │
[Auto-Change (30-day schedule)]
    │
    ├─ Generate new 32-char password (complexity enforced)
    ├─ Set-ADAccountPassword on domain
    ├─ Verify new password works (heartbeat)
    ├─ Update secret in Vault
    └─ Log rotation event
```

### Decommission: Secret Revocation (v2)

In `Remove-ServiceAccount.ps1`:
```
POST /api/v1/secrets/{id} (PATCH)
  autoChangeEnabled: false
  enableHeartbeat: false
  active: false
```

---

## 4–9: Remaining Sections

_(Unchanged from v1 — see original `05-secrets-rotation.md` for:)_

- **Section 4:** Database Rotation (PostgreSQL + SQL Server via Delinea heartbeat)
- **Section 5:** Entra SP Rotation (Delinea DSV → Graph API)
- **Section 6:** AWS SM IAM User Access Key Rotation (Lambda-based)
- **Section 7:** Application Secret Retrieval Patterns (A through E)
- **Section 8:** Emergency Rotation Procedure
- **Section 9:** Rotation Monitoring & Alerting
