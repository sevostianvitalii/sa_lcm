# accounts/databases/svc_billing_prod_pg.tf
# PostgreSQL Database Service Account — Billing (Production)
# Provisioned via Terraform cyrilgdn/postgresql provider

module "svc_billing_prod_pg" {
  source = "../../modules/database-account"

  name            = "billing"
  environment     = "prod"
  engine          = "postgresql"
  description     = "Billing service read/write access to billing DB"
  jira_ticket     = "SACM-401"
  technical_owner = "payments.team@bank.com"

  db_host           = "pg-billing-prod.bank.internal"
  default_database  = "billing_prod"
  connection_limit  = 20

  pg_grants = {
    billing_tables = {
      database    = "billing_prod"
      schema      = "public"
      object_type = "table"
      privileges  = ["SELECT", "INSERT", "UPDATE"]
    }
    billing_sequences = {
      database    = "billing_prod"
      schema      = "public"
      object_type = "sequence"
      privileges  = ["USAGE", "SELECT"]
    }
  }

  delinea_folder_id = "3010"  # Prod / Database Accounts
}
