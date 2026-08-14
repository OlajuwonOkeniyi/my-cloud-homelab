output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.homelab.id
}

output "public_ip" {
  description = "Public IP address of the instance"
  value       = aws_instance.homelab.public_ip
}
