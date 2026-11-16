terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
  default_tags {
    tags = { Project = "invigrid" }
  }
}

locals {
  name = "invigrid"
}

data "aws_availability_zones" "azs" {
  state = "available"
}

# VPC (Public + Private Subnets + 1 NAT Gateway)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = "${local.name}-vpc"
  cidr            = "10.10.0.0/16"
  azs             = slice(data.aws_availability_zones.azs.names, 0, 2)
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true
  enable_dns_support   = true
}

#  Private EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${local.name}-eks"
  kubernetes_version = "1.36"

  endpoint_private_access = true
  endpoint_public_access  = false

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    general = {
      name           = "${local.name}-ng"
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 2
    }
  }
}

#  Private SSM Proxy EC2 (no public IP, no open inbound ports)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "proxy" {
  name = "${local.name}-ssm-proxy-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "proxy_ssm" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "proxy" {
  name = "${local.name}-ssm-proxy-profile"
  role = aws_iam_role.proxy.name
}

resource "aws_security_group" "proxy" {
  name   = "${local.name}-ssm-proxy-sg"
  vpc_id = module.vpc.vpc_id
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "eks_from_proxy" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.proxy.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_instance" "ssm_proxy" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.proxy.id]
  iam_instance_profile   = aws_iam_instance_profile.proxy.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y squid
    cat << 'SQUID' > /etc/squid/squid.conf
    acl SSL_ports port 443
    acl CONNECT method CONNECT
    http_access deny !SSL_ports
    http_access allow localhost
    http_access deny all
    http_port 127.0.0.1:8888
    SQUID
    systemctl enable --now squid
  EOF

  tags = { Name = "${local.name}-ssm-proxy" }
}

# Map SSO Roles into EKS Access Entries
data "aws_caller_identity" "current" {}
data "aws_iam_session_context" "current" { arn = data.aws_caller_identity.current.arn }

data "aws_iam_roles" "sso_admin" { name_regex = "^AWSReservedSSO_${local.name}-eks-admin_.*" }
data "aws_iam_roles" "sso_dev"   { name_regex = "^AWSReservedSSO_${local.name}-eks-dev_.*" }

resource "aws_eks_access_entry" "admin" {
  for_each      = setsubtract(data.aws_iam_roles.sso_admin.arns, [data.aws_iam_session_context.current.issuer_arn])
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = aws_eks_access_entry.admin
  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}

resource "aws_eks_access_entry" "dev" {
  for_each          = data.aws_iam_roles.sso_dev.arns
  cluster_name      = module.eks.cluster_name
  principal_arn     = each.value
  kubernetes_groups = ["${local.name}-dev-group"]
  user_name         = "${local.name}-dev-user"
}

output "ssm_proxy_id" { value = aws_instance.ssm_proxy.id }
output "cluster_arn"  { value = module.eks.cluster_arn }