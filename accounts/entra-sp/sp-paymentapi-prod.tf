# accounts/entra-sp/sp-paymentapi-prod.tf
# Entra ID Service Principal — Payment API (Production)
# Provisioned via Terraform azuread provider

module "sp_paymentapi_prod" {
  source = "../../modules/entra-service-principal"

  name            = "paymentapi"
  environment     = "prod"
  description     = "Payment processing API — OAuth2 client credentials for backend-to-backend auth"
  jira_ticket     = "SACM-201"
  technical_owner = "payments.team@bank.com"

  credential_type = "certificate"  # Preferred for production (no secret rotation needed)

  api_permissions = {
    graph_user_read = {
      role_id            = "df021288-bdef-4463-88db-98f22de89214"  # User.Read.All
      resource_object_id = data.azuread_service_principal.msgraph.object_id
    }
    graph_mail_send = {
      role_id            = "b633e1c5-b582-4048-a93e-9f11b44c7e96"  # Mail.Send
      resource_object_id = data.azuread_service_principal.msgraph.object_id
    }
  }

  delinea_folder_id = "2010"  # Prod / Entra Service Principals
}
