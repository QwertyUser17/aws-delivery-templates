# Role for GitHub Actions through OIDC: no AWS keys in the repository settings.
# The permissions cover build, scan and deploy-ec2 for this one repository and instance.

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_role" "ci" {
  name = "${var.name}-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = [for repo in var.github_repositories : "repo:${repo}:*"] }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci" {
  name = "delivery"
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushPullAndLifecycle"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:PutLifecyclePolicy",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "RunDeployCommand"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:${local.partition}:ssm:${var.region}::document/AWS-RunShellScript",
          aws_instance.app.arn,
        ]
      },
      {
        Sid      = "ReadDeployCommand"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:CancelCommand"]
        Resource = "*"
      },
      {
        Sid    = "DeployOutput"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
        ]
        Resource = [aws_cloudwatch_log_group.deploy.arn, "${aws_cloudwatch_log_group.deploy.arn}:*"]
      },
    ]
  })
}
