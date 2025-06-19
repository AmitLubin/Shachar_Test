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

# Data sources for existing resources
data "aws_subnet" "existing_subnet" {
  id = "subnet-088b7d937a4cd5d85"
}

data "aws_security_group" "existing_sg" {
  id = "sg-0ac3749215afde82a"
}

data "aws_vpc" "existing_vpc" {
  id = data.aws_subnet.existing_subnet.vpc_id
}

# Get additional subnets in the VPC for ALB (ALB requires at least 2 subnets in different AZs)
data "aws_subnets" "vpc_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing_vpc.id]
  }
}

# Data source for existing ECS Cluster
data "aws_ecs_cluster" "imtech_cluster" {
  cluster_name = "imtech"
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "nginx_logs" {
  name              = "/ecs/amit-imtech-nginx"
  retention_in_days = 7

  tags = {
    Name = "imtech-nginx-logs"
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "nginx_task" {
  family                   = "imtech-nginx-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = "arn:aws:iam::314525640319:role/ecsTaskExecutionRole"

  container_definitions = jsonencode([
    {
      name  = "nginx"
      image = "nginx:latest"
      essential = true
      
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx_logs.name
          "awslogs-region"        = "il-central-1"
          "awslogs-stream-prefix" = "nginx"
        }
      }

      mountPoints = [
        {
          sourceVolume  = "nginx-logs"
          containerPath = "/var/log/nginx"
          readOnly      = false
        }
      ]
    },
    {
      name  = "log-forwarder"
      image = "fluent/fluent-bit:latest"
      essential = false
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nginx_logs.name
          "awslogs-region"        = "il-central-1"
          "awslogs-stream-prefix" = "log-forwarder"
        }
      }

      mountPoints = [
        {
          sourceVolume  = "nginx-logs"
          containerPath = "/var/log/nginx"
          readOnly      = true
        }
      ]

      environment = [
        {
          name  = "LOGSTASH_HOST"
          value = "172.29.80.10"
        },
        {
          name  = "LOGSTASH_PORT"
          value = "6789"
        }
      ]

      command = [
        "/fluent-bit/bin/fluent-bit",
        "--config=/fluent-bit/etc/fluent-bit.conf"
      ]

      # Custom Fluent Bit configuration
      dockerLabels = {
        "fluent-bit-config" = base64encode(<<-EOF
[SERVICE]
    Flush         1
    Log_Level     info
    Daemon        off
    Parsers_File  parsers.conf

[INPUT]
    Name              tail
    Path              /var/log/nginx/access.log
    Path_Key          filename
    Parser            nginx
    Tag               nginx.access
    Refresh_Interval  5

[INPUT]
    Name              tail
    Path              /var/log/nginx/error.log
    Path_Key          filename
    Parser            nginx_error
    Tag               nginx.error
    Refresh_Interval  5

[OUTPUT]
    Name  tcp
    Match nginx.*
    Host  172.29.80.10
    Port  6789
    Format json_lines

[PARSER]
    Name        nginx
    Format      regex
    Regex       ^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*)(?: "(?<referer>[^\"]*)" "(?<agent>[^\"]*)")?$
    Time_Key    time
    Time_Format %d/%b/%Y:%H:%M:%S %z

[PARSER]
    Name        nginx_error
    Format      regex
    Regex       ^(?<time>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(?<level>\w+)\] (?<pid>\d+).(?<tid>\d+): (?<message>.*)$
    Time_Key    time
    Time_Format %Y/%m/%d %H:%M:%S
EOF
        )
      }
    }
  ])

  volume {
    name = "nginx-logs"
  }

  tags = {
    Name = "imtech-nginx-task-definition"
  }
}

# Application Load Balancer
data "aws_lb" "imtec" {
  name = "imtec"  # Provide the name of the existing ALB
}

# ALB Target Group
resource "aws_lb_target_group" "nginx_tg" {
  name        = "imtech-nginx-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.existing_vpc.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name = "imtech-nginx-target-group"
  }
}

# ALB Listener
resource "aws_lb_listener" "nginx_listener" {
  load_balancer_arn = data.aws_lb.imtec.arn
  port              = "9988"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx_tg.arn
  }

  tags = {
    Name = "imtech-nginx-listener"
  }
}

# ECS Service
resource "aws_ecs_service" "nginx_service" {
  name            = "imtech-amit-nginx-service"
  cluster         = data.aws_ecs_cluster.imtech_cluster.id
  task_definition = aws_ecs_task_definition.nginx_task.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [data.aws_security_group.existing_sg.id]
    subnets         = [data.aws_subnet.existing_subnet.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx_tg.arn
    container_name   = "nginx"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.nginx_listener]

  tags = {
    Name = "imtech-nginx-service"
  }
}

# Outputs
output "ecs_cluster_name" {
  description = "Name of the existing ECS cluster"
  value       = data.aws_ecs_cluster.imtech_cluster.cluster_name
}

output "load_balancer_dns" {
  description = "DNS name of the load balancer"
  value       = data.aws_lb.imtec.dns_name
}

output "load_balancer_port" {
  description = "Port of the load balancer listener"
  value       = aws_lb_listener.nginx_listener.port
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.nginx_service.name
}

output "task_definition_arn" {
  description = "ARN of the task definition"
  value       = aws_ecs_task_definition.nginx_task.arn
}