# Part A — Networking (VPC, Subnets, Gateways)
# ──────────────────────────────────────────────────────────
# DATA SOURCE: Get all available Availability Zones in the region
# This lets Terraform automatically pick 'us-east-1a' and 'us-east-1b'
# without hardcoding them.
# ──────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {}

# ──────────────────────────────────────────────────────────
# VPC: Your private network in AWS
# Everything you create lives inside this network boundary.
# enable_dns_hostnames = true lets resources get DNS names like
# 'ip-10-0-0-5.ec2.internal'
# ──────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

# ──────────────────────────────────────────────────────────
# INTERNET GATEWAY: The VPC's door to the public internet
# Without this, nothing in the VPC can reach the internet.
# ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# ──────────────────────────────────────────────────────────
# PUBLIC SUBNETS (x2): One per Availability Zone
# count = 2 means Terraform creates 2 copies of this resource.
# cidrsubnet splits the VPC CIDR into smaller blocks:
#   count.index 0 → 10.0.0.0/24
#   count.index 1 → 10.0.1.0/24
# map_public_ip_on_launch = true gives resources here a public IP
# ──────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${count.index + 1}" }
}

# ──────────────────────────────────────────────────────────
# PRIVATE SUBNETS (x2): Where Lambda runs
# No public IPs. count.index + 2 gives different CIDR blocks:
#   10.0.2.0/24 and 10.0.3.0/24
# ──────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project_name}-private-${count.index + 1}" }
}

# ──────────────────────────────────────────────────────────
# ELASTIC IPs for NAT Gateways
# A NAT Gateway needs a static public IP address. EIP provides this.
# ──────────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip-${count.index + 1}" }
}

# ──────────────────────────────────────────────────────────
# NAT GATEWAYS (x2): One per AZ for high availability
# Lambda (in private subnets) needs to reach the internet
# (e.g., to call external payment APIs). The NAT Gateway sits
# in the public subnet and forwards traffic out on Lambda's behalf.
# Lambda's private IP is never exposed to the internet.
# ──────────────────────────────────────────────────────────
resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw]

  tags = { Name = "${var.project_name}-nat-${count.index + 1}" }
}

# ──────────────────────────────────────────────────────────
# ROUTE TABLE (Public): Sends internet traffic to IGW
# 0.0.0.0/0 means 'all internet traffic'
# ──────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ──────────────────────────────────────────────────────────
# ROUTE TABLES (Private): One per AZ, routes through NAT
# Each private subnet gets its own route table pointing to
# the NAT Gateway in the same AZ. This ensures traffic stays
# within the same AZ if that NAT goes down.
# ──────────────────────────────────────────────────────────
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "${var.project_name}-rt-private-${count.index + 1}" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Part B — Security Groups
# ──────────────────────────────────────────────────────────
# SECURITY GROUP for Lambda
# Think of a security group as a firewall around a resource.
# ingress = inbound traffic rules
# egress  = outbound traffic rules
#
# Lambda doesn't receive direct connections from the internet
# (API Gateway calls it internally), so we allow no inbound traffic.
# We allow all outbound traffic so Lambda can reach DynamoDB.
# ──────────────────────────────────────────────────────────
resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security group for Lambda function"
  vpc_id      = aws_vpc.main.id

  # No inbound rules — Lambda is invoked by API Gateway, not directly

  egress {
    from_port   = 0       # All ports
    to_port     = 0
    protocol    = "-1"    # All protocols
    cidr_blocks = ["0.0.0.0/0"]  # Allow all outbound
  }

  tags = { Name = "${var.project_name}-lambda-sg" }
}

# Part C — DynamoDB Table
# ──────────────────────────────────────────────────────────
# DYNAMODB TABLE: Where payment records are stored
# billing_mode = PAY_PER_REQUEST means you only pay per read/write
# — no upfront capacity to configure. Perfect for variable workloads.
# hash_key = 'id' is the primary key. Every payment gets a unique UUID.
# ──────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "payments" {
  name         = "Payments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"  # S = String
  }

  # Enable point-in-time recovery — lets you restore to any second in last 35 days
  point_in_time_recovery { enabled = true }

  tags = {
    Name             = "Payments"
    Backup_Frequency = "daily"   # Required by our Config compliance rule
  }
}

# Part D — IAM Role for Lambda
# ──────────────────────────────────────────────────────────
# IAM ROLE FOR LAMBDA
# The 'assume_role_policy' is a trust policy — it answers:
# 'WHO is allowed to use this role?'
# Here we say: only the Lambda service can assume this role.
# ──────────────────────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

# Basic execution: allows Lambda to create CloudWatch log groups + write logs
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC access: allows Lambda to create/delete network interfaces in your VPC
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# DynamoDB access: allows Lambda to put/get items from DynamoDB
resource "aws_iam_role_policy_attachment" "lambda_dynamo" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# Part E — Lambda Function
# ──────────────────────────────────────────────────────────
# LAMBDA FUNCTION
# filename: path to the zip file of your code (built by build.sh)
# handler: 'filename.exportedFunctionName' → handler.js exports 'handler'
# runtime: nodejs18.x is the Node.js version Lambda will use
# environment.variables: passes the DynamoDB table name as an env var
#   so you don't hardcode 'Payments' inside your Lambda code
# vpc_config: places Lambda inside your private subnets
#   so it's not directly accessible from the internet
# ──────────────────────────────────────────────────────────
resource "aws_lambda_function" "api" {
  function_name = "${var.project_name}-api"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "nodejs18.x"
  filename      = "${path.module}/../lambda/function.zip"

  # Terraform will redeploy Lambda if this hash changes (i.e., your code changed)
  source_code_hash = filebase64sha256("${path.module}/../lambda/function.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.payments.name
    }
  }

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id  # Both private subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  tags = { Name = "${var.project_name}-api" }
}

# Part F — API Gateway
# ──────────────────────────────────────────────────────────
# API GATEWAY (HTTP API v2)
# HTTP API is cheaper and simpler than REST API.
# It's the modern way to build Lambda-backed APIs.
# ──────────────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

# ──────────────────────────────────────────────────────────
# INTEGRATION: Connects API Gateway to your Lambda function
# AWS_PROXY means API Gateway forwards the entire HTTP request
# to Lambda — including headers, body, query params — and
# Lambda's response becomes the HTTP response.
# ──────────────────────────────────────────────────────────
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# ──────────────────────────────────────────────────────────
# ROUTE: Maps HTTP method + path to an integration
# 'POST /payments' → Lambda integration
# ──────────────────────────────────────────────────────────
resource "aws_apigatewayv2_route" "post_payment" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /payments"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# ──────────────────────────────────────────────────────────
# STAGE: A deployment stage. 'prod' becomes part of your URL.
# auto_deploy = true means changes deploy automatically.
# ──────────────────────────────────────────────────────────
resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "prod"
  auto_deploy = true

  # Access logging — captures every API request
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = "$context.requestId $context.httpMethod $context.routeKey $context.status $context.responseLength"
  }
}

# ──────────────────────────────────────────────────────────
# LAMBDA PERMISSION: Allows API Gateway to invoke Lambda
# Without this, API Gateway gets a 403 'Access Denied' when
# trying to call your Lambda function.
# ──────────────────────────────────────────────────────────
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# Part G — Observability (CloudWatch, SNS)
# ──────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUPS
# retention_in_days = 30 means logs are automatically deleted
# after 30 days to avoid unnecessary storage costs.
# ──────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-api"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 30
}

# ──────────────────────────────────────────────────────────
# CLOUDWATCH ALARM: Triggers if Lambda errors spike
# threshold = 5 means: if Lambda has 5+ errors in 5 minutes,
# send an SNS alert.
# ──────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = 5

  dimensions = { FunctionName = aws_lambda_function.api.function_name }

  alarm_actions = [aws_sns_topic.alerts.arn]
  alarm_description = "Lambda error rate is high"
}

# ──────────────────────────────────────────────────────────
# SNS TOPIC: The notification channel
# You can subscribe your email to this topic in the AWS Console
# (SNS → Topics → fintrust-alerts → Create Subscription → Email)
# ──────────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# Part H — AWS Config Compliance Rule
# ──────────────────────────────────────────────────────────
# AWS CONFIG: Compliance monitoring
# Config continuously evaluates your resources against rules.
# This rule checks that all resources have a 'Backup_Frequency' tag.
#
# IMPORTANT: AWS Config must be enabled in your account first.
# Go to: AWS Console → Config → Get Started → Turn on recording
# ──────────────────────────────────────────────────────────
resource "aws_config_config_rule" "required_tags" {
  name = "required-backup-tag"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"  # AWS managed rule
  }

  # The tag key that must exist on resources
  input_parameters = jsonencode({
    tag1Key = "Backup_Frequency"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Config recorder: tells Config what resources to monitor
resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    all_supported = true  # Monitor all resource types
  }
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# S3 bucket where Config stores compliance history
resource "aws_s3_bucket" "config_logs" {
  bucket        = "${var.project_name}-config-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # Allows Terraform to delete this bucket on destroy
}

data "aws_caller_identity" "current" {}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

# IAM role for Config service
resource "aws_iam_role" "config_role" {
  name = "${var.project_name}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-delivery"
  role = aws_iam_role.config_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.config_logs.arn}/AWSLogs/*"
    }]
  })
}


