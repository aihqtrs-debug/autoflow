variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "Deployment environment name (dev, prod, etc.)"
  type        = string
  default     = "dev"
}

variable "owner_tag" {
  description = "Who owns/built this project (shows up on every resource for cost tracking)"
  type        = string
  default     = "aihqtrs"
}

variable "notification_email" {
  description = "Email address to receive job completion/failure notifications"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI/CD deploy role, as \"org-or-user/repo-name\". The default matches no real repo, so the role is inert until this is set to the real value."
  type        = string
  default     = "CHANGEME/CHANGEME"
}

variable "github_branch" {
  description = "Branch the CI/CD deploy role's trust policy is scoped to"
  type        = string
  default     = "main"
}
