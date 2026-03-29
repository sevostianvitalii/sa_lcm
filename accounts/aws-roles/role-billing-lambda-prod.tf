# accounts/aws-roles/role-billing-lambda-prod.tf
# AWS IAM Role — Billing Lambda Function (Production)
# Provisioned via Terraform aws provider

module "role_billing_lambda_prod" {
  source = "../../modules/aws-iam-role"

  name            = "billing"
  service_type    = "lambda"       # Trust policy: lambda.amazonaws.com
  environment     = "prod"
  description     = "Billing service Lambda — processes payment events from SQS"
  jira_ticket     = "SACM-310"
  technical_owner = "payments.team@bank.com"

  max_session_seconds = 3600

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSQS"
        Effect   = "Allow"
        Action   = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = "arn:aws:sqs:eu-west-1:123456789012:billing-events-prod"
      },
      {
        Sid      = "WriteDynamoDB"
        Effect   = "Allow"
        Action   = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = "arn:aws:dynamodb:eu-west-1:123456789012:table/billing-transactions-prod"
      },
      {
        Sid      = "ReadSecrets"
        Effect   = "Allow"
        Action   = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:billing/*"
      }
    ]
  })
}
