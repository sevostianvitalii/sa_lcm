# accounts/entra-mi/mi-reportgen-prod.tf
# Entra ID Managed Identity — Report Generator (Production)
# User-assigned Managed Identity — no secrets, token via Azure IMDS

module "mi_reportgen_prod" {
  source = "../../modules/entra-managed-identity"

  name            = "reportgen"
  environment     = "prod"
  description     = "Report generator service — accesses Azure Storage and Key Vault"
  jira_ticket     = "SACM-218"
  technical_owner = "data.team@bank.com"

  resource_group  = "rg-reporting-prod"
  location        = "westeurope"

  role_assignments = {
    storage_blob = {
      scope                = "/subscriptions/xxx/resourceGroups/rg-reporting-prod/providers/Microsoft.Storage/storageAccounts/streportsprod"
      role_definition_name = "Storage Blob Data Reader"
    }
    keyvault_secrets = {
      scope                = "/subscriptions/xxx/resourceGroups/rg-reporting-prod/providers/Microsoft.KeyVault/vaults/kv-reports-prod"
      role_definition_name = "Key Vault Secrets User"
    }
  }
}
