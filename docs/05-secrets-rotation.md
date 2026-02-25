# Secrets & Rotation Design — Delinea + AWS Secrets Manager

---

## 1. Secret Management Decision Matrix

| Account Type | Secret Exists? | Manager | Rotation Method | Rotation Interval |
|---|:---:|---|---|---|
| AD Service Account | ✅ Password | **Delinea PAM/DSV** | Heartbeat auto-rotate | 30 days |
| gMSA | ❌ (AD-managed) | AD KDS Root Key | Native AD | 30 days |
| Entra SP (secret) | ✅ Client Secret | **Delinea DSV** | Delinea → Entra ID API | 90 days |
| Entra SP (cert) | ✅ Private Key | **Delinea DSV** | PKI renewal + Terraform | 1 year |
| Entra Managed Identity | ❌ | Azure platform | N/A | N/A |
| AWS IAM Role | ❌ | STS token | N/A (assumed) | N/A |
| AWS IAM User (legacy) | ✅ Access Key | **AWS SM** | Lambda rotation function | 30 days |
| Linux SA (no sudo) | ❌ | N/A | N/A | N/A |
| Linux SA (SSH key) | ✅ SSH Key | **Delinea PAM** | Delinea SSH key rotate | 90 days |
| Database Account | ✅ Password | **Delinea PAM** | Heartbeat auto-rotate | 30 days |
| API Key / Token | ✅ Token | **Delinea DSV** | Assisted/manual trigger | 90 days max |

---

## 2. Delinea Architecture

### Products in Use

| Product | Role | Use Cases |
|---|---|---|
| **Delinea Secret Server (PAM)** | Full PAM with checkout, session recording, heartbeat | AD accounts, gMSA validation, DB accounts, Linux SSH |
| **Delinea DevOps Secrets Vault (DSV)** | API-first, CI/CD-native secret storage | Entra SP secrets, API keys, CI/CD injected secrets |

### Folder Structure in Secret Server

```
VaultRoot/
├── 📁 Production/
│   ├── 📁 AD-Service-Accounts/
│   │   ├── 🔑 svc-billing-prod
│   │   ├── 🔑 svc-reporting-prod
│   │   └── ...
│   ├── 📁 Database-Accounts/
│   │   ├── 🔑 svc_billing_sqlprod@sqlserver01.bank.local
│   │   └── ...
│   ├── 📁 Entra-Service-Principals/
│   │   ├── 🔑 sp-paymentapi-prod
│   │   └── ...
│   ├── 📁 Linux-Service-Accounts/
│   │   └── 🔑 svc_billing@linuxhost01
│   └── 📁 API-Keys/
│       └── 🔑 apikey-stripe-prod
├── 📁 Staging/
│   └── ... (mirrored structure)
└── 📁 Dev/
    └── ... (mirrored structure)
```

### Secret Templates (Custom)

| Template ID | Name | Fields |
|---|---|---|
| `6001` | AD Service Account | Username, Password, Domain, OU, Notes |
| `6002` | AD Service Account + Heartbeat | As above + heartbeat check enabled |
| `6010` | Entra SP - Client Secret | Client ID, Client Secret, Tenant ID, App Name |
| `6011` | Entra SP - Certificate | Client ID, Certificate PFX, Thumbprint, Tenant ID |
| `6020` | PostgreSQL Service Account | Server, Port, Database, Username, Password |
| `6021` | SQL Server Service Account | Server, Instance, Database, Username, Password |
| `6030` | Linux SSH Key | Hostname, Username, Private Key, Public Key |
| `6040` | API Key / Token | Service Name, Token, Token URL, Expiry Date |

---

## 3. Delinea Secret Server — AD Account Rotation

### How It Works

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

### RPC Heartbeat Configuration (per secret)
```
Heartbeat: Enabled
Heartbeat Interval: 24 hours
Heartbeat Failure Limit: 3 attempts before alert
Auto-Change: Enabled
Auto-Change Schedule: Every 30 days
Auto-Change Trigger: Heartbeat failure OR schedule

Alert on Failure: iam-ops@bank.com + Jira webhook (create "Secret Rotation" issue)
```

### Delinea RPC Script for AD (custom if using DSV)
```python
# execution/delinea_rotate_ad.py
"""
Rotates AD service account password via Delinea and AD API.
Called by Delinea auto-change workflow.
"""
import ldap3
import secrets
import string
import os
from delinea.vault import VaultClient

VAULT_URL = os.environ["DELINEA_DSV_URL"]
VAULT_CLIENT_ID = os.environ["DELINEA_CLIENT_ID"]
VAULT_CLIENT_SECRET = os.environ["DELINEA_CLIENT_SECRET"]

def generate_password(length=32):
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*()"
    while True:
        pwd = ''.join(secrets.choice(alphabet) for _ in range(length))
        if (any(c.isupper() for c in pwd) and
            any(c.islower() for c in pwd) and
            any(c.isdigit() for c in pwd) and
            any(c in "!@#$%^&*()" for c in pwd)):
            return pwd

def rotate_ad_account(secret_path: str, domain: str, dc: str):
    client = VaultClient(url=VAULT_URL, client_id=VAULT_CLIENT_ID, client_secret=VAULT_CLIENT_SECRET)
    secret = client.get_secret(secret_path)
    
    username = secret["data"]["username"]
    new_password = generate_password()
    
    # Connect to AD and change password (requires LDAPS)
    server = ldap3.Server(dc, use_ssl=True, port=636)
    conn = ldap3.Connection(server, user=f"{domain}\\svc-delinea-rotator", 
                            password=os.environ["ROTATOR_PASSWORD"])
    conn.bind()
    
    # Change the target account's password
    user_dn = f"CN={username},OU=ServiceAccounts,OU=Prod,DC=bank,DC=local"
    conn.extend.microsoft.modify_password(user_dn, new_password)
    
    if conn.result["result"] != 0:
        raise Exception(f"Failed to change AD password: {conn.result}")
    
    # Update Delinea vault with new password
    client.update_secret(secret_path, {"password": new_password})
    
    print(f"✅ Rotated password for {username}")
    return True
```

---

## 4. Delinea Secret Server — Database Rotation

### PostgreSQL Rotation Configuration

```
Secret Template: PostgreSQL Service Account (6020)

Rotation Script: Built-in PostgreSQL changer
  - Connects as rotator account (svc_delinea_rotator)
  - Executes: ALTER ROLE {username} WITH PASSWORD '{new_password}';
  - Verifies connection with new password (heartbeat)

Heartbeat Query: SELECT 1;
Heartbeat Frequency: Every 24 hours
Rotation Frequency: Every 30 days

Rotator Account:
  - Username: svc_delinea_rotator
  - Permissions: CREATEROLE or specific ALTER ROLE on service accounts
```

### SQL Server Rotation Configuration

```
Secret Template: SQL Server Service Account (6021)

Rotation Script: Built-in SQL Server changer
  - Executes: ALTER LOGIN {username} WITH PASSWORD = '{new_password}';
  - Verifies with new password

Rotator Account: delinea_rotator (SQL login with ALTER ANY LOGIN permission)
```

---

## 5. Delinea DSV — Entra Service Principal Rotation

### Architecture

```
[Delinea DSV Rotation Trigger - 90 days]
    │
    ├─ Call Entra ID Graph API
    │   POST /applications/{appId}/addPassword
    │   → returns new client_secret_value + keyId
    │
    ├─ Update DSV secret with new client_secret_value + keyId
    │
    ├─ Wait 1 hour (propagation grace period)
    │
    ├─ Verify new secret works:
    │   POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
    │   → validate access token returned
    │
    ├─ Delete old secret from Entra:
    │   POST /applications/{appId}/removePassword
    │   body: {"keyId": "{old_keyId}"}
    │
    └─ Log + notify Jira webhook
```

### DSV Rotation Script

```python
# execution/delinea_rotate_entra_sp.py
"""
Rotates Entra ID Service Principal client secret via Graph API.
Triggered by Delinea DSV rotation engine.
"""
import requests
import os
import json
from datetime import datetime, timedelta

def rotate_entra_sp(tenant_id: str, app_id: str, dsv_secret_path: str):
    # Get admin credentials for Graph API from DSV
    admin_token = get_graph_admin_token(tenant_id)
    
    headers = {
        "Authorization": f"Bearer {admin_token}",
        "Content-Type": "application/json"
    }
    
    # 1. Create new secret (validity: 90 days)
    new_secret_body = {
        "passwordCredential": {
            "displayName": f"Delinea-managed-{datetime.now().strftime('%Y%m')}",
            "endDateTime": (datetime.now() + timedelta(days=90)).isoformat() + "Z"
        }
    }
    
    resp = requests.post(
        f"https://graph.microsoft.com/v1.0/applications/{app_id}/addPassword",
        headers=headers,
        json=new_secret_body
    )
    resp.raise_for_status()
    new_cred = resp.json()
    new_secret_value = new_cred["secretText"]
    new_key_id = new_cred["keyId"]
    
    # 2. Update DSV with new secret
    update_dsv_secret(dsv_secret_path, {
        "clientSecret": new_secret_value,
        "keyId": new_key_id
    })
    
    # 3. Verify new secret works
    verify_token = test_entra_sp_auth(tenant_id, app_id, new_secret_value)
    if not verify_token:
        raise Exception("New secret verification failed - NOT removing old secret")
    
    # 4. Get old keyId from previous rotation (stored in DSV as prevKeyId)
    old_key_id = get_dsv_field(dsv_secret_path, "prevKeyId")
    if old_key_id:
        remove_old_body = {"keyId": old_key_id}
        requests.post(
            f"https://graph.microsoft.com/v1.0/applications/{app_id}/removePassword",
            headers=headers,
            json=remove_old_body
        )
    
    # 5. Store current keyId as prevKeyId for next rotation
    update_dsv_secret(dsv_secret_path, {"prevKeyId": new_key_id})
    
    print(f"✅ Entra SP {app_id} secret rotated successfully")
```

---

## 6. AWS Secrets Manager — IAM User Access Key Rotation

### Architecture (Lambda-based)

```
[AWS SM Rotation Schedule - 30 days]
    │
    ├─ Lambda: createSecret
    │   AWS API: create_access_key(UserName=svc_user)
    │   Store new AKID + secret in SM staging label
    │
    ├─ Lambda: setSecret
    │   Notify consuming application (if applicable via tag)
    │   Update app config if push-model is configured
    │
    ├─ Lambda: testSecret
    │   Use new AKID to call sts:GetCallerIdentity
    │   Verify returns correct ARN
    │
    └─ Lambda: finishSecret
        Move label AWSCURRENT → new key
        Delete old access key: delete_access_key(AccessKeyId=old_akid)
```

### CloudFormation / Terraform for Rotation

```hcl
# In modules/aws-iam-user-legacy/main.tf
resource "aws_secretsmanager_secret" "iam_key" {
  name        = "svc/${var.name}/${var.environment}/iam-credentials"
  description = "${var.description} | Ticket: ${var.jira_ticket}"
  
  tags = {
    Rotation = "enabled"
    Owner    = var.technical_owner
  }
}

resource "aws_secretsmanager_secret_rotation" "iam_key_rotation" {
  secret_id           = aws_secretsmanager_secret.iam_key.id
  rotation_lambda_arn = data.aws_lambda_function.iam_key_rotator.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

---

## 7. Application Secret Retrieval Patterns

To avoid hardcoding credentials in configuration files or code, applications must retrieve secrets dynamically at runtime or deployment time.

### Pattern A: Delinea Secret Server REST API (On-Prem Apps & Linux Daemons)

For traditional VM-based applications, scripts, or IIS pools.

```python
# python example - fetching at startup
import requests
import os

DELINEA_URL = "https://delinea.bank.local/SecretServer"

def get_db_credentials(secret_id):
    # 1. Authenticate (using a dedicated app-fetcher account or OAuth token)
    auth_resp = requests.post(f"{DELINEA_URL}/oauth2/token", data={
        "grant_type": "password",
        "username": os.environ["APP_IDENTITY_USER"],
        "password": os.environ["APP_IDENTITY_PASS"]
    })
    token = auth_resp.json()["access_token"]
    
    # 2. Fetch the specific secret
    sec_resp = requests.get(
        f"{DELINEA_URL}/api/v1/secrets/{secret_id}",
        headers={"Authorization": f"Bearer {token}"}
    )
    secret_data = sec_resp.json()
    
    # 3. Extract fields (Delinea returns an array of fields)
    fields = {f["slug"]: f["itemValue"] for f in secret_data["items"]}
    return fields["username"], fields["password"]
```

**Security Note:** The `APP_IDENTITY` used to authenticate to Delinea should be tied to the machine (e.g., using a certificate) or injected via your deployment tool.

### Pattern B: Delinea DSV SDK (Cloud-Native & Container Apps)

For modern containerized apps or Entra/AWS workloads where Delinea DSV is used.

```go
// go example using DSV SDK
package main

import (
	"fmt"
	"os"
	"github.com/DelineaXPM/dsv-sdk-go/v2/vault"
)

func main() {
	// DSV SDK automatically picks up DSV_CLIENT_ID and DSV_CLIENT_SECRET 
	// from environment variables (injected by K8s or pipeline)
	v, _ := vault.New(vault.Configuration{
		Tenant: "bank-dsv-tenant",
	})
	
	secret, _ := v.Secret("Production/Database-Accounts/svc_billing_pgprod")
	pass := secret.Data["password"].(string)
	
	fmt.Printf("Connected using dynamic password length %d\n", len(pass))
}
```

### Pattern C: Kubernetes External Secrets Operator (EKS/AKS/On-Prem)

The recommended approach for Kubernetes. The application code doesn't change; it still reads environment variables or files, but the cluster fetches from Delinea.

```yaml
# 1. Provide the cluster access to Delinea DSV
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: delinea-dsv
spec:
  provider:
    delinea:
      tenant: "bank-dsv-tenant"
      clientId:
        name: dsv-credentials
        key: clientId
      clientSecret:
        name: dsv-credentials
        key: clientSecret

---
# 2. Map the specific Delinea secret to a K8s native Secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: billing-db-credentials
spec:
  refreshInterval: 1h  # Automatically catches Delinea 30-day rotations
  secretStoreRef:
    name: delinea-dsv
    kind: ClusterSecretStore
  target:
    name: billing-db-k8s-secret  # The K8s secret your pod mounts
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: Production/Database-Accounts/svc_billing_pgprod
        property: password
```

### Pattern D: CI/CD Pipeline Injection (GitLab)

For infrastructure scripts (Terraform/Ansible) or deployment scripts requiring external API keys.

```yaml
# .gitlab-ci.yml — using Delinea DSV CLI in the runner
deploy:
  image: registry.gitlab.bank.internal/platform/deployer:dsv
  before_script:
    # Authenticate DSV CLI
    - dsv init --client-id $DSV_CI_CLIENT --client-secret $DSV_CI_SECRET
    # Fetch the token exactly when needed into an ephemeral variable
    - export STRIPE_KEY=$(dsv secret read Production/API-Keys/stripe_prod --field Token)
  script:
    - ./deploy_payment_gateway.sh
```

### Pattern E: AWS SM SDK (for legacy AWS workloads)

```python
import boto3
import json

def get_db_creds():
    client = boto3.client("secretsmanager", region_name="eu-central-1")
    secret = client.get_secret_value(SecretId="svc/billing/prod/iam-credentials")
    return json.loads(secret["SecretString"])
```

---

## 8. Emergency Rotation Procedure

```
TRIGGER: Suspected credential compromise, security incident, or employee termination
         (employee had access to check out the account)

Step 1: Log Emergency in Jira
  - Create "Emergency Break-Glass" or "Secret Rotation" issue
  - Link to incident (P-number)
  - Obtain CISO approval in ticket

Step 2: Immediate Disable (within 15 minutes of detection)
  - AD accounts: Disable-ADAccount -Identity svc-{name}-prod
  - Entra SP: Revoke-AzureADApplicationPassword
  - AWS IAM User: aws iam update-access-key --status Inactive
  - DB accounts: ALTER LOGIN {name} DISABLE

Step 3: Force-Rotate in Delinea (within 1 hour)
  - Open Delinea Secret Server
  - Navigate to secret → Actions → Force Change Now
  - Verify heartbeat succeeds with new credentials

Step 4: Re-enable Account
  - Only after rotation confirmed successful
  - Re-enable in respective identity system

Step 5: Audit & Notify
  - Pull Delinea checkout log for incident period
  - Determine all systems that could have used the credential
  - Notify security team of exposure window
  - Update Jira rotation ticket with timeline

Step 6: Post-Incident
  - Terraform drift check (ensure nothing changed)
  - Review checkout policy (restrict if over-liberal)
  - Update SOP if process failed anywhere
```

---

## 9. Rotation Monitoring & Alerting

| Event | Source | Alert Target |
|---|---|---|
| Rotation failed (heartbeat) | Delinea | iam-ops@bank.com + Jira issue |
| Secret expiry approaching < 30d | Delinea schedule check | Technical Owner + iam-ops |
| Rotation succeeded | Delinea | Audit log only |
| AWS SM rotation failed | CloudWatch metric | SNS → iam-ops@bank.com |
| Emergency rotation triggered | Jira automation | CISO + iam-ops + Security |
| Secret checkout > 24h | Delinea | iam-ops@bank.com |
| Secret checked out by non-owner | Delinea | Security team |
