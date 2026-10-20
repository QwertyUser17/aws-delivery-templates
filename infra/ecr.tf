# The build template also creates the repository when it is missing. Its lifecycle
# policy is not set here: build applies it from policies/ecr-lifecycle.json, and two
# owners of the same policy would undo each other.
resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_cloudwatch_log_group" "deploy" {
  name              = local.log_group
  retention_in_days = 14
}
