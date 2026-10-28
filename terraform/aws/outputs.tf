output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Command to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the generated database password"
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}
