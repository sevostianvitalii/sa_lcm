# Terraform Module Design — Service Account Lifecycle

---

## 1. Repository Structure

```
service-accounts/                        ← GitLab repo (dedicated)
├── .gitlab-ci.yml                       ← CI/CD pipeline definition
├── README.md
├── terraform.tfvars.example
│
├── providers/                           ← Provider version pins
│   ├── versions.tf
│   └── providers.tf
│
├── modules/                             ← Reusable modules (the "tools")
│   ├── ad-service-account/
│   ├── gmsa/
│   ├── entra-service-principal/
│   ├── entra-managed-identity/
│   ├── aws-iam-role/
│   ├── aws-iam-user-legacy/
│   ├── linux-service-account/
│   ├── database-account/
│   └── api-key-secret/
│
├── accounts/                            ← Account declarations (one file per account)
│   ├── ad/
│   │   ├── svc-billing-prod.tf
│   │   ├── svc-reporting-prod.tf
│   │   └── ...
│   ├── gmsa/
│   ├── entra-sp/
│   ├── entra-mi/
│   ├── aws-roles/
│   ├── linux/
│   ├── databases/
│   └── api-keys/
│
├── environments/                        ← Per-env backend config
│   ├── prod/
│   │   └── backend.tf
│   ├── staging/
│   │   └── backend.tf
│   └── dev/
│       └── backend.tf
│
└── scripts/
    ├── drift-detect.sh                  ← Scheduled drift detection
    ├── orphan-detect.sh                 ← Find accounts not in Terraform state
    └── validate-naming.py              ← Pre-commit naming convention check
```

---

## 2. Provider Configuration

```hcl
# providers/versions.tf
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # Active Directory (on-prem)
    activedirectory = {
      source  = "hashicorp/ad"
      version = "~> 0.5"
    }

    # Entra ID / Azure AD
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

    # Delinea DSV (for secret registration)
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

## 3. State Backend

```hcl
# environments/prod/backend.tf
terraform {
  backend "s3" {
    bucket         = "bank-tfstate-service-accounts"
    key            = "prod/service-accounts.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "bank-tfstate-lock"
    
    # Use IAM Role (no static keys)
    role_arn = "arn:aws:iam::123456789012:role/role-terraform-state-prod"
  }
}
```

---

## 4. Module: `ad-service-account`

```hcl
# modules/ad-service-account/variables.tf
variable "name" {
  description = "Service account name (without svc- prefix)"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-21 chars."
  }
}

variable "environment" {
  description = "Environment (prod, staging, dev)"
  type        = string
}

variable "description" {
  description = "Purpose of the account. Include Jira ticket reference."
  type        = string
}

variable "ou_path" {
  description = "OU path in AD (e.g., OU=ServiceAccounts,OU=prod,DC=bank,DC=local)"
  type        = string
}

variable "member_of_groups" {
  description = "List of AD group DNs this account should be member of"
  type        = list(string)
  default     = []
}

variable "jira_ticket" {
  description = "Jira ticket reference (e.g., SACM-123)"
  type        = string
}

variable "technical_owner" {
  description = "Owner's username or email"
  type        = string
}

variable "delinea_folder_id" {
  description = "Delinea Secret Server folder ID for this environment"
  type        = string
}
```

```hcl
# modules/ad-service-account/main.tf
locals {
  full_name   = "svc-${var.name}-${var.environment}"
  description = "${var.description} | Owner: ${var.technical_owner} | Ticket: ${var.jira_ticket}"
}

resource "random_password" "initial" {
  length           = 32
  special          = true
  override_special = "!@#$%^&*()"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "ad_user" "service_account" {
  display_name     = local.full_name
  sam_account_name = local.full_name
  principal_name   = "${local.full_name}@bank.local"
  initial_password = random_password.initial.result
  container        = var.ou_path
  description      = local.description

  # Security flags
  cannot_change_password  = true
  password_never_expires  = false  # Rotation handled by Delinea
  smart_card_required     = false
}

resource "ad_group_membership" "memberships" {
  for_each = toset(var.member_of_groups)
  
  group_id  = each.value
  group_members = [ad_user.service_account.id]
}

# Register secret in Delinea immediately after creation
resource "delinea_secret" "ad_password" {
  name      = local.full_name
  folder_id = var.delinea_folder_id
  
  secret_template_id = 6002  # AD Service Account template in Delinea

  fields {
    field_name = "Username"
    value      = local.full_name
  }
  fields {
    field_name = "Password"
    value      = random_password.initial.result
  }
  fields {
    field_name = "Domain"
    value      = "bank.local"
  }
  fields {
    field_name = "Notes"
    value      = local.description
  }

  # Enable auto-rotation heartbeat
  enable_auto_change = true
}
```

```hcl
# modules/ad-service-account/outputs.tf
output "sam_account_name" {
  value       = ad_user.service_account.sam_account_name
  description = "SAM account name for AD"
}

output "distinguished_name" {
  value       = ad_user.service_account.dn
  description = "Distinguished name for group memberships etc."
}

output "delinea_secret_id" {
  value       = delinea_secret.ad_password.id
  description = "Delinea secret ID for this account's credentials"
  sensitive   = true
}
```

---

## 5. Module: `entra-service-principal`

```hcl
# modules/entra-service-principal/main.tf
locals {
  app_name    = "sp-${var.name}-${var.environment}"
}

resource "azuread_application" "app" {
  display_name = local.app_name
  description  = "${var.description} | Owner: ${var.technical_owner} | Ticket: ${var.jira_ticket}"
  owners       = [data.azuread_user.owner.object_id]
}

resource "azuread_service_principal" "sp" {
  client_id = azuread_application.app.client_id
  owners    = [data.azuread_user.owner.object_id]
}

# Client Secret path
resource "time_rotating" "secret_rotation" {
  count         = var.credential_type == "secret" ? 1 : 0
  rotation_days = 89  # Rotate before Delinea picks up (90-day policy)
}

resource "azuread_application_password" "secret" {
  count             = var.credential_type == "secret" ? 1 : 0
  application_id    = azuread_application.app.id
  display_name      = "Terraform-managed - rotated ${formatdate("YYYY-MM", timestamp())}"
  end_date_relative = "2160h"  # 90 days

  rotate_when_changed = {
    rotation = time_rotating.secret_rotation[0].id
  }
}

# Certificate path
resource "tls_private_key" "cert_key" {
  count     = var.credential_type == "certificate" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "cert" {
  count           = var.credential_type == "certificate" ? 1 : 0
  private_key_pem = tls_private_key.cert_key[0].private_key_pem

  subject {
    common_name  = local.app_name
    organization = "Bank Name"
  }

  validity_period_hours = 8760  # 1 year
  early_renewal_hours   = 720   # 30-day early renewal

  allowed_uses = ["digital_signature", "key_encipherment", "client_auth"]
}

resource "azuread_application_certificate" "cert" {
  count          = var.credential_type == "certificate" ? 1 : 0
  application_id = azuread_application.app.id
  type           = "AsymmetricX509Cert"
  value          = tls_self_signed_cert.cert[0].cert_pem
  end_date       = tls_self_signed_cert.cert[0].validity_end_time
}

# Store in Delinea
resource "delinea_secret" "sp_credential" {
  name      = local.app_name
  folder_id = var.delinea_folder_id

  secret_template_id = var.credential_type == "secret" ? 6010 : 6011  # SP Secret / SP Cert templates

  fields {
    field_name = "Client ID"
    value      = azuread_application.app.client_id
  }

  dynamic "fields" {
    for_each = var.credential_type == "secret" ? [1] : []
    content {
      field_name = "Client Secret"
      value      = azuread_application_password.secret[0].value
    }
  }

  fields {
    field_name = "Tenant ID"
    value      = data.azuread_client_config.current.tenant_id
  }
}

# API Permissions
resource "azuread_app_role_assignment" "api_permissions" {
  for_each = var.api_permissions

  app_role_id         = each.value.role_id
  principal_object_id = azuread_service_principal.sp.object_id
  resource_object_id  = each.value.resource_object_id
}
```

---

## 6. Module: `aws-iam-role`

```hcl
# modules/aws-iam-role/main.tf
locals {
  role_name = "role-${var.name}-${var.service_type}-${var.environment}"
}

data "aws_iam_policy_document" "trust" {
  # EC2 trust
  dynamic "statement" {
    for_each = var.service_type == "ec2" ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "Service"
        identifiers = ["ec2.amazonaws.com"]
      }
    }
  }

  # Lambda trust
  dynamic "statement" {
    for_each = var.service_type == "lambda" ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "Service"
        identifiers = ["lambda.amazonaws.com"]
      }
    }
  }

  # GitLab OIDC trust
  dynamic "statement" {
    for_each = var.service_type == "gitlab-oidc" ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [var.gitlab_oidc_provider_arn]
      }
      condition {
        test     = "StringLike"
        variable = "gitlab.bank.internal:sub"
        values   = var.gitlab_project_paths  # e.g., ["project_path:group/repo:ref_type:branch:ref:main"]
      }
    }
  }

  # Cross-account trust
  dynamic "statement" {
    for_each = var.service_type == "cross-account" ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = var.trusted_account_arns
      }
      condition {
        test     = "BoolIfExists"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "role" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
  description        = "${var.description} | Owner: ${var.technical_owner} | Ticket: ${var.jira_ticket}"
  
  max_session_duration = var.max_session_seconds  # default 3600

  tags = {
    Environment    = var.environment
    Owner          = var.technical_owner
    JiraTicket     = var.jira_ticket
    ManagedBy      = "terraform"
    ReviewDate     = timeadd(timestamp(), "8760h")  # +1 year
  }
}

resource "aws_iam_policy" "policy" {
  name   = "policy-${local.role_name}"
  policy = var.policy_json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.policy.arn
}

# EC2 Instance Profile
resource "aws_iam_instance_profile" "profile" {
  count = var.service_type == "ec2" ? 1 : 0
  name  = "profile-${local.role_name}"
  role  = aws_iam_role.role.name
}
```

---

## 7. Module: `database-account`

```hcl
# modules/database-account/main.tf
# Supports: postgresql, mssql engines
# DB account created via engine-specific provider; password stored in Delinea

locals {
  account_name = "svc_${replace(var.name, "-", "_")}_${var.environment}"
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!@#$%*()-_=+"
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# PostgreSQL path
resource "postgresql_role" "pg_svc" {
  count    = var.engine == "postgresql" ? 1 : 0
  name     = local.account_name
  login    = true
  password = random_password.db_password.result
  
  connection_limit = var.connection_limit  # default 10
}

resource "postgresql_grant" "pg_permissions" {
  for_each    = var.engine == "postgresql" ? var.pg_grants : {}
  
  database    = each.value.database
  role        = postgresql_role.pg_svc[0].name
  schema      = each.value.schema
  object_type = each.value.object_type
  privileges  = each.value.privileges
}

# SQL Server path
resource "mssql_login" "mssql_svc" {
  count          = var.engine == "mssql" ? 1 : 0
  server         = var.mssql_server_config
  login_name     = local.account_name
  password       = random_password.db_password.result
  
  must_change_password     = false
  default_database         = var.default_database
  default_language         = "English"
  check_expiration_enabled = false  # Delinea manages rotation
  check_policy_enabled     = true
}

# Store in Delinea with DB-specific template
resource "delinea_secret" "db_credential" {
  name      = "${local.account_name}@${var.db_host}"
  folder_id = var.delinea_folder_id

  secret_template_id = var.engine == "postgresql" ? 6020 : 6021  # PG / MSSQL templates

  fields {
    field_name = "Server"
    value      = var.db_host
  }
  fields {
    field_name = "Database"
    value      = var.default_database
  }
  fields {
    field_name = "Username"
    value      = local.account_name
  }
  fields {
    field_name = "Password"
    value      = random_password.db_password.result
  }

  # Delinea heartbeat: verifies connection after rotation
  enable_auto_change = true
  heartbeat_enabled  = true
}
```

---

## 8. Account Declaration (Consumer) Example

```hcl
# accounts/ad/svc-billing-prod.tf
module "svc_billing_prod" {
  source = "../../modules/ad-service-account"

  name            = "billing"
  environment     = "prod"
  description     = "Billing service Windows host account for scheduled task execution"
  ou_path         = "OU=ServiceAccounts,OU=Prod,DC=bank,DC=local"
  jira_ticket     = "SACM-142"
  technical_owner = "john.smith@bank.com"
  
  member_of_groups = [
    "CN=GRP_Billing_Service,OU=Groups,DC=bank,DC=local",
    "CN=GRP_FileShare_Billing_RW,OU=Groups,DC=bank,DC=local"
  ]
  
  delinea_folder_id = "1042"  # Prod / AD Service Accounts folder
}
```

---

## 9. GitLab CI/CD Pipeline

```yaml
# .gitlab-ci.yml
stages:
  - validate
  - plan
  - apply
  - drift-detect

variables:
  TF_VAR_FILE: "environments/${CI_ENVIRONMENT_NAME}/backend.tf"
  TF_LOG: "WARN"

.terraform-base:
  image: registry.gitlab.bank.internal/platform/terraform:1.7-delinea
  before_script:
    - terraform init -backend-config="environments/${ENV}/backend.tf"

validate:
  extends: .terraform-base
  stage: validate
  script:
    - terraform validate
    - python3 scripts/validate-naming.py accounts/
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

plan:
  extends: .terraform-base
  stage: plan
  script:
    - terraform plan -out=tfplan.binary
    - terraform show -json tfplan.binary > tfplan.json
  artifacts:
    paths: [tfplan.binary, tfplan.json]
    expire_in: 7 days
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

# Triggered by Jira webhook via GitLab API
apply:
  extends: .terraform-base
  stage: apply
  script:
    - terraform apply -auto-approve tfplan.binary
    - echo "Apply complete - update Jira ticket ${JIRA_TICKET}"
  environment:
    name: $ENV
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  when: manual  # Requires explicit trigger after MR merge

drift-detect:
  extends: .terraform-base
  stage: drift-detect
  script:
    - bash scripts/drift-detect.sh
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"  # Runs nightly
  allow_failure: false
```

---

## 10. Drift Detection Script

```bash
#!/bin/bash
# scripts/drift-detect.sh

set -euo pipefail

echo "=== Terraform Drift Detection ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

terraform plan -detailed-exitcode -out=/tmp/drift-plan.binary 2>&1
PLAN_EXIT_CODE=$?

case $PLAN_EXIT_CODE in
  0)
    echo "✅ No drift detected"
    ;;
  1)
    echo "❌ Terraform plan failed — check provider connectivity"
    exit 1
    ;;
  2)
    echo "⚠️  DRIFT DETECTED — changes pending"
    terraform show -json /tmp/drift-plan.binary | \
      jq '.resource_changes[] | select(.change.actions != ["no-op"]) | {resource: .address, action: .change.actions}'
    
    # Post alert to Jira via REST API
    curl -s -X POST "${JIRA_API_URL}/rest/api/3/issue" \
      -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"fields\": {
          \"project\": {\"key\": \"SACM\"},
          \"summary\": \"DRIFT ALERT: Service accounts out of sync with Terraform state\",
          \"issuetype\": {\"name\": \"Alert\"},
          \"priority\": {\"name\": \"High\"},
          \"description\": {\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": \"Drift detected in pipeline ${CI_PIPELINE_URL}\"}]}]}
        }
      }"
    exit 2
    ;;
esac
```
