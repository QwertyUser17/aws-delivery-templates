output "instance_id" {
  description = "For deploy-ec2 instance-id."
  value       = aws_instance.app.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  description = "For aws-role-arn in the workflows."
  value       = aws_iam_role.ci.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.deploy.name
}
