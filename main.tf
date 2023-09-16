terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

locals {
  availability_zones = ["${var.aws_region}a", "${var.aws_region}c"]
}

# ========================= VPC network design =========================
# https://javatodev.com/how-to-build-aws-vpc-using-terraform-step-by-step/#Define_provider_with_an_AWS_region
# VPC
resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# Public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = length(var.public_subnets_cidr)
  cidr_block              = element(var.public_subnets_cidr, count.index)
  availability_zone       = element(local.availability_zones, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-${element(local.availability_zones, count.index)}-public-subnet"
    Environment = "${var.environment}"
  }
}

# Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = length(var.private_subnets_cidr)
  cidr_block              = element(var.private_subnets_cidr, count.index)
  availability_zone       = element(local.availability_zones, count.index)
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment}-${element(local.availability_zones, count.index)}-private-subnet"
    Environment = "${var.environment}"
  }
}

#Internet gateway
resource "aws_internet_gateway" "ig" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    "Name"        = "${var.environment}-igw"
    "Environment" = var.environment
  }
}

# Elastic-IP (eip) for NAT
resource "aws_eip" "nat_eip" {
  vpc        = true
  depends_on = [aws_internet_gateway.ig]
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = element(aws_subnet.public_subnet.*.id, 0)
  tags = {
    Name        = "nat-gateway-${var.environment}"
    Environment = "${var.environment}"
  }
}

# Routing tables to route traffic for Private Subnet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name        = "${var.environment}-private-route-table"
    Environment = "${var.environment}"
  }
}

# Routing tables to route traffic for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name        = "${var.environment}-public-route-table"
    Environment = "${var.environment}"
  }
}

# Route for Internet Gateway
resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ig.id
}

# Route for NAT Gateway
resource "aws_route" "private_internet_gateway" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# Route table associations for both Public & Private Subnets
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets_cidr)
  subnet_id      = element(aws_subnet.public_subnet.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets_cidr)
  subnet_id      = element(aws_subnet.private_subnet.*.id, count.index)
  route_table_id = aws_route_table.private.id
}


# ========================= Security Group =========================
resource "aws_security_group" "public_security_group" {
  name = "${var.environment}-sg"
  description = "Allow my SSH traffic publicSG"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description      = "SSH from my Home"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = [ var.my_home_ip ]
    ipv6_cidr_blocks = []
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${var.environment}-sg"
  }
}

resource "aws_security_group" "private_security_group" {
  name = "${var.environment}-private-sg"
  description = "Allow my SSH traffic privateSG"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description      = "SSH from my Home"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = [ var.my_home_ip ]
    ipv6_cidr_blocks = []
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${var.environment}-sg"
  }
}

# ========================= EC2 instance =========================
# https://www.sammeechward.com/terraform-vpc-subnets-ec2-and-more
# One EC2 instance per public subnet
resource "aws_instance" "public_instance" {
  ami           = "ami-0f844a9675b22ea32" # Amazon Linux 2 AMI (HVM)
  instance_type = "t2.micro"
  key_name = var.ssh_key_pair

  count                   = length(var.public_subnets_cidr)
  availability_zone       = element(local.availability_zones, count.index)
  subnet_id = element(aws_subnet.public_subnet.*.id, count.index)
  vpc_security_group_ids = [ aws_security_group.public_security_group.id ]
  associate_public_ip_address = true

  tags = {
    Name        = "${var.environment}-public_ec2-${count.index}"
  }
}

# One EC2 instance per private subnet
resource "aws_instance" "private_instance" {
  ami           = "ami-0f844a9675b22ea32" # Amazon Linux 2 AMI (HVM)
  instance_type = "t2.micro"
  key_name = var.ssh_key_pair

  count                   = length(var.private_subnets_cidr)
  availability_zone       = element(local.availability_zones, count.index)
  subnet_id = element(aws_subnet.private_subnet.*.id, count.index)
  vpc_security_group_ids = [ aws_security_group.private_security_group.id ]

  tags = {
    Name        = "${var.environment}-private_ec2-${count.index}"
  }
}