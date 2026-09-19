# -----------------------------------------------------------------------------
# CI/CD identity: GitHub Actions assumes this role via OIDC federation to run
# `terraform plan`/`apply` and sync the frontend — no long-lived AWS access
# keys stored as a GitHub secret, which is the whole point of OIDC federation.
#
# The trust policy is scoped to one specific repo + branch (var.github_repo,
# default "main"), so only workflow runs from that exact repo/ref can assume
# this role. Until var.github_repo is set to a real "org/repo", it defaults to
# a value that matches no real GitHub repository, so this role is inert.
#
# The attached policy is scoped by resource-name-prefix ("autoflow-dev-*")
# everywhere the IAM ARN format supports it. A handful of AWS services don't
# support resource-level permissions at all for the actions Terraform needs
# (CloudFront, Cognito user-pool IDs, the IAM OIDC-provider list call) - those
# statements are called out individually below rather than folded silently
# into a blanket "*" everywhere. This is still far narrower than the
# AdministratorAccess used for manual/CloudShell operations.
# -----------------------------------------------------------------------------

locals {
  # Names of the remote-state bucket/lock-table this deploy role needs access
  # to. Bootstrapped once by hand outside Terraform (see docs/ci-cd-setup.md)
  # to avoid the chicken-and-egg problem of Terraform managing its own backend.
  tf_state_bucket = "${local.name_prefix}-terraform-state-${local.account_id}"
  tf_lock_table   = "${local.name_prefix}-terraform-locks"
}

# Fetched live rather than hardcoded from memory - AWS validates the actual
# TLS chain for well-known OIDC providers like GitHub regardless of this
# value, but the field is still required, and a live fetch is more honest
# than a thumbprint typed in by hand.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.tf_state_bucket}/autoflow/terraform.tfstate"
      },
      {
        Sid      = "TerraformStateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.tf_state_bucket}"
      },
      {
        Sid      = "TerraformLockTable"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${local.tf_lock_table}"
      },
      {
        Sid      = "AppS3Buckets"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = ["arn:aws:s3:::${local.name_prefix}-*", "arn:aws:s3:::${local.name_prefix}-*/*"]
      },
      {
        Sid      = "AppLambdaFunctions"
        Effect   = "Allow"
        Action   = "lambda:*"
        Resource = "arn:aws:lambda:${var.aws_region}:${local.account_id}:function:${local.name_prefix}-*"
      },
      {
        Sid      = "AppDynamoDBTables"
        Effect   = "Allow"
        Action   = "dynamodb:*"
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${local.name_prefix}-*",
          "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${local.name_prefix}-*/index/*",
        ]
      },
      {
        Sid      = "AppSNSTopics"
        Effect   = "Allow"
        Action   = "sns:*"
        Resource = "arn:aws:sns:${var.aws_region}:${local.account_id}:${local.name_prefix}-*"
      },
      {
        Sid      = "AppSQSQueues"
        Effect   = "Allow"
        Action   = "sqs:*"
        Resource = "arn:aws:sqs:${var.aws_region}:${local.account_id}:${local.name_prefix}-*"
      },
      {
        Sid      = "AppStepFunctions"
        Effect   = "Allow"
        Action   = "states:*"
        Resource = "arn:aws:states:${var.aws_region}:${local.account_id}:stateMachine:${local.name_prefix}-*"
      },
      {
        Sid      = "AppEventBridgeRules"
        Effect   = "Allow"
        Action   = "events:*"
        Resource = "arn:aws:events:${var.aws_region}:${local.account_id}:rule/${local.name_prefix}-*"
      },
      {
        Sid      = "AppLogGroups"
        Effect   = "Allow"
        Action   = "logs:*"
        Resource = [
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-*:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/${local.name_prefix}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/${local.name_prefix}-*:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/states/${local.name_prefix}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/states/${local.name_prefix}-*:*",
        ]
      },
      {
        Sid      = "AppLogResourcePolicy"
        Effect   = "Allow"
        Action   = ["logs:DescribeResourcePolicies", "logs:PutResourcePolicy", "logs:DeleteResourcePolicy"]
        Resource = "*" # this action family is account-scoped, not resource-scoped, in the IAM policy language
      },
      {
        Sid      = "AppLogGroupsDescribe"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:ListTagsForResource"]
        Resource = "*"
      },
      {
        Sid      = "AppCloudWatchAlarmsAndDashboard"
        Effect   = "Allow"
        Action   = ["cloudwatch:*"]
        Resource = [
          "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${local.name_prefix}-*",
          "arn:aws:cloudwatch::${local.account_id}:dashboard/${local.name_prefix}-*",
        ]
      },
      {
        Sid      = "AppCloudWatchDescribe"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:ListDashboards", "cloudwatch:GetDashboard"]
        Resource = "*" # CloudWatch's read/list actions don't support resource-level restriction
      },
      {
        Sid      = "AppCloudTrail"
        Effect   = "Allow"
        Action   = "cloudtrail:*"
        Resource = "arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${local.name_prefix}-*"
      },
      {
        Sid    = "AppCloudTrailDescribe"
        Effect = "Allow"
        Action = [
          "cloudtrail:DescribeTrails", "cloudtrail:GetTrailStatus", "cloudtrail:GetEventSelectors",
          "cloudtrail:GetInsightSelectors", "cloudtrail:ListTags",
        ]
        Resource = "*"
      },
      {
        Sid      = "AppBudget"
        Effect   = "Allow"
        Action   = "budgets:*"
        Resource = "arn:aws:budgets::${local.account_id}:budget/${local.name_prefix}-*"
      },
      {
        Sid      = "AppIAMRoles"
        Effect   = "Allow"
        Action = [
          "iam:CreateRole", "iam:GetRole", "iam:DeleteRole", "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
          "iam:PassRole", "iam:ListAttachedRolePolicies",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"
      },
      {
        Sid      = "AppIAMOidcProvider"
        Effect   = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider",
          "iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
      },
      {
        Sid      = "AppIAMOidcProviderList"
        Effect   = "Allow"
        Action   = ["iam:ListOpenIDConnectProviders"]
        Resource = "*" # this list action has no resource-level ARN form
      },
      {
        Sid      = "AppApiGatewayHttpApi"
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = ["arn:aws:apigateway:${var.aws_region}::/apis", "arn:aws:apigateway:${var.aws_region}::/apis/*"]
        # HTTP APIs are identified by an opaque ID assigned at creation, not by
        # name, so IAM can't scope this to "just AutoFlow's API" - it's scoped
        # to the API Gateway service/region instead of account-wide "*".
      },
      {
        Sid      = "AppCognito"
        Effect   = "Allow"
        Action   = "cognito-idp:*"
        Resource = "arn:aws:cognito-idp:${var.aws_region}:${local.account_id}:userpool/*"
        # Same story as API Gateway: Cognito user pool IDs are opaque and
        # assigned at creation, so this is scoped to the service/region/account
        # rather than to a specific pool.
      },
      {
        Sid    = "AppCloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateDistribution", "cloudfront:GetDistribution", "cloudfront:UpdateDistribution",
          "cloudfront:DeleteDistribution", "cloudfront:TagResource", "cloudfront:UntagResource",
          "cloudfront:ListDistributions", "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation",
          "cloudfront:CreateOriginAccessControl", "cloudfront:GetOriginAccessControl",
          "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
          "cloudfront:ListTagsForResource",
        ]
        Resource = "*" # CloudFront's IAM actions do not support resource-level permissions at all
      },
      {
        Sid      = "ReadCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}
