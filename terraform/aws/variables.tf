variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name. \"production\" turns on deletion protection and final snapshots."
  type        = string
  default     = "demo"
}

variable "name" {
  description = "Prefix for all resources"
  type        = string
  default     = "paypoint"
}

variable "vpc_cidr" {
  description = "VPC address range"
  type        = string
  default     = "10.20.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (e.g. your office IP /32)"
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Restrict the EKS API to specific CIDRs; 0.0.0.0/0 is not allowed."
  }
}

variable "node_instance_types" {
  description = "Instance types for the managed node group (several types improve Spot availability)"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}
