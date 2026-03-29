# accounts/aws-roles/role-cicd-gitlab-prod.tf
# AWS IAM Role — GitLab CI/CD OIDC (Production)
# Uses OIDC federation — no static credentials

module "role_cicd_gitlab_prod" {
  source = "../../modules/aws-iam-role"

  name            = "cicd"
  service_type    = "gitlab-oidc"
  environment     = "prod"
  description     = "GitLab CI/CD pipeline — deploys to prod ECS and S3"
  jira_ticket     = "SACM-315"
  technical_owner = "platform.team@bank.com"

  gitlab_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/gitlab.bank.internal"
  gitlab_project_paths     = ["project_path:platform/infrastructure:ref_type:branch:ref:main"]

  max_session_seconds = 3600

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DeployECS"
        Effect   = "Allow"
        Action   = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Sid      = "DeployS3"
        Effect   = "Allow"
        Action   = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::bank-deployments-prod",
          "arn:aws:s3:::bank-deployments-prod/*"
        ]
      }
    ]
  })
}
