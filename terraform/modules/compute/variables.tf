variable "project_name" {
  description = "Name prefix for resources"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "ssh_public_key" {
  description = "Public SSH key content"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed SSH access"
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the instance in"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
}
