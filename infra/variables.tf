variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix of the resources."
  type        = string
  default     = "delivery-example"
}

variable "instance_type" {
  description = "Instance type. x86: the example image is built for linux/amd64."
  type        = string
  default     = "t3.micro"
}

variable "ecr_repository" {
  description = "ECR repository the pipeline pushes to."
  type        = string
  default     = "web"
}

variable "container_name" {
  description = "Container name on the instance. The deploy log group is named after it."
  type        = string
  default     = "web"
}

variable "github_repositories" {
  description = "Repositories (owner/name) allowed to assume the CI role."
  type        = list(string)
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set to false if the account already has one."
  type        = bool
  default     = true
}
