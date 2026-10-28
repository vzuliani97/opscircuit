data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)
  production = var.environment == "production"
}

# Network: private subnets for nodes, public subnets for load balancers, isolated subnets for the database.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

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
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

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

resource "aws_db_instance" "postgres" {
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

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = local.production

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = local.production
  skip_final_snapshot        = !local.production
  final_snapshot_identifier  = local.production ? "${var.name}-final" : null
}

# Container registries for the PayPoint images.
resource "aws_ecr_repository" "app" {
  for_each = toset(["paypoint-backend", "paypoint-frontend"])

  name                 = each.key
  image_tag_mutability = "IMMUTABLE" # a tag always points to the same image

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
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
