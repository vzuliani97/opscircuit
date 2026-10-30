locals {
  azs        = var.availability_zones
  production = var.environment == "production"
}

# Network: private subnets for nodes, public subnets for load balancers, isolated subnets for the database.
# Official registry modules, pinned to exact versions and locked in .terraform.lock.hcl.
module "vpc" {
  #checkov:skip=CKV_TF_1:Registry module pinned to an exact version; provider hashes are in the lock file
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]      # 10.20.0.0/20 ...
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)] # 10.20.48.0/24 ...
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 52 + i)] # 10.20.52.0/24 ...

  create_database_subnet_group = true
  enable_dns_hostnames         = true
  enable_nat_gateway           = true
  # One NAT gateway keeps the demo cheap; production would use one per AZ.
  single_nat_gateway = !local.production

  # Tags the AWS Load Balancer Controller uses to find subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  #checkov:skip=CKV_TF_1:Registry module pinned to an exact version; provider hashes are in the lock file
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      # Spot is much cheaper; the API runs 2 replicas with a PodDisruptionBudget, so it tolerates interruptions.
      capacity_type = local.production ? "ON_DEMAND" : "SPOT"
      min_size      = 1
      max_size      = 3
      desired_size  = 2
    }
  }
}

# PostgreSQL in isolated subnets, reachable only from the EKS nodes.
resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL access from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS nodes"
}

# Logs slow queries (over 1 s) and schema changes to CloudWatch.
resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.name}-pg16-"
  family      = "postgres16"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Reject unencrypted connections: data in transit is always TLS.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "postgres" {
  #checkov:skip=CKV_AWS_118:Enhanced monitoring needs an extra IAM role and adds cost; Performance Insights covers the demo
  #checkov:skip=CKV_AWS_354:Performance Insights uses the AWS-managed KMS key; a customer-managed key adds cost for a demo
  identifier     = var.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true

  db_name  = "paypoint"
  username = "paypoint"
  # RDS generates the password and keeps it in Secrets Manager: it never appears in Terraform state or code.
  manage_master_user_password = true
  # Pods can authenticate with short-lived IAM tokens instead of a static password.
  iam_database_authentication_enabled = true

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  multi_az               = local.production

  backup_retention_period         = 7
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true
  auto_minor_version_upgrade      = true
  deletion_protection             = local.production
  skip_final_snapshot             = !local.production
  final_snapshot_identifier       = local.production ? "${var.name}-final" : null
}

# Container registries for the PayPoint images.
resource "aws_ecr_repository" "app" {
  for_each = toset(["paypoint-backend", "paypoint-frontend"])

  name                 = each.key
  image_tag_mutability = "IMMUTABLE" # a tag always points to the same image

  image_scanning_configuration {
    scan_on_push = true
  }

  # KMS with the AWS-managed key (aws/ecr): audited key usage, no extra key cost.
  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
