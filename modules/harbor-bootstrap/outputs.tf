output "robot_name" {
  description = "Full Harbor robot name including the `robot$<project>+` prefix Harbor adds. Use as docker login username."
  value       = data.external.robot.result.name
}

output "robot_secret" {
  description = "Harbor robot password / token. Sensitive."
  value       = data.external.robot.result.secret
  sensitive   = true
}
