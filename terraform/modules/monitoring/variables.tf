variable "project_name" {
  description = "Name prefix for resources"
  type        = string
}

variable "instance_id" {
  description = "EC2 instance ID to monitor"
  type        = string
}

variable "alert_email" {
  description = "Email for alarm notifications"
  type        = string
}

variable "aws_region" {
  description = "AWS region (for dashboard widget config)"
  type        = string
}
