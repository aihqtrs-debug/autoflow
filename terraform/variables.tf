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
