# Configure the AWS Provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "il-central-1"
}

# Data source to get the latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Data source to get existing subnet information
data "aws_subnet" "existing_subnet" {
  id = "subnet-088b7d937a4cd5d85"
}

data "aws_subnet" "existing_subnet2" {
  id = "subnet-01e6348062924d048"
}

# Data source to get existing security group
data "aws_security_group" "existing_sg" {
  id = "sg-0ac3749215afde82a"
}

# Create a key pair for SSH access
resource "aws_key_pair" "vm_key" {
  key_name   = "vm-keypair"
  public_key = file("/home/test/.ssh/aws_key")
}

# EC2 Instance
resource "aws_instance" "vm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name              = aws_key_pair.vm_key.key_name
  vpc_security_group_ids = [data.aws_security_group.existing_sg.id]
  subnet_id             = data.aws_subnet.existing_subnet.id

  # Disable source/destination check for NAT instances (if needed)
  source_dest_check = true

  tags = {
    Name        = "Private-VM-Ubuntu"
    Environment = "dev"
  }

  # User data script for initial setup
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y mysql-client
              EOF
}

# Create DB subnet group for RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [
    data.aws_subnet.existing_subnet.id,
    data.aws_subnet.existing_subnet2.id  # RDS requires at least 2 subnets in different AZs
  ]

  tags = {
    Name = "RDS DB subnet group"
  }
}


# Security group for RDS
resource "aws_security_group" "rds_sg" {
  name        = "rds-mysql-sg"
  description = "Security group for RDS MySQL instance"
  vpc_id      = data.aws_subnet.existing_subnet.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [data.aws_security_group.existing_sg.id]  
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "RDS MySQL Security Group"
  }
}

# RDS MySQL Instance
resource "aws_db_instance" "mysql" {
  identifier                = "mysql-instance"
  allocated_storage         = 20
  max_allocated_storage     = 100
  storage_type              = "gp2"
  engine                    = "mysql"
  engine_version            = "8.0"
  instance_class            = "db.t3.micro"
  db_name                   = "myapp"
  username                  = "admin"
  password                  = "aA123456"
  parameter_group_name      = "default.mysql8.0"
  db_subnet_group_name      = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  publicly_accessible = false
  
  skip_final_snapshot = true
  
  storage_encrypted = true
  
  tags = {
    Name        = "MySQL RDS Instance"
    Environment = "dev"
  }
}

# Outputs
output "vm_private_ip" {
  description = "Private IP address of the VM"
  value       = aws_instance.vm.private_ip
}

output "vm_instance_id" {
  description = "Instance ID of the VM"
  value       = aws_instance.vm.id
}

output "rds_endpoint" {
  description = "RDS MySQL endpoint"
  value       = aws_db_instance.mysql.endpoint
}

output "rds_port" {
  description = "RDS MySQL port"
  value       = aws_db_instance.mysql.port
}

output "database_name" {
  description = "Database name"
  value       = aws_db_instance.mysql.db_name
}