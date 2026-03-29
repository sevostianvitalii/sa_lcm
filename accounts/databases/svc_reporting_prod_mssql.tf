# accounts/databases/svc_reporting_prod_mssql.tf
# SQL Server Database Service Account — Reporting (Production)
# Provisioned via Terraform betr-io/mssql provider

module "svc_reporting_prod_mssql" {
  source = "../../modules/database-account"

  name            = "reporting"
  environment     = "prod"
  engine          = "mssql"
  description     = "Reporting service read-only access to analytics DB"
  jira_ticket     = "SACM-410"
  technical_owner = "dba.team@bank.com"

  db_host          = "mssql-analytics-prod.bank.internal"
  default_database = "AnalyticsProd"

  mssql_server_config = {
    host = "mssql-analytics-prod.bank.internal"
    port = 1433
  }

  delinea_folder_id = "3011"  # Prod / Database Accounts / MSSQL
}
