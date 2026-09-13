data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.cluster_state_bucket
    key    = var.terraform_state_key
    region = var.region
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = var.database_state_bucket
    key    = var.database_state_key
    region = var.region
  }
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "aws_lb" "internal_api" {
  name = "workshop-api-internal"
}

data "aws_lb_listener" "internal_api" {
  load_balancer_arn = data.aws_lb.internal_api.arn
  port              = 80
}

locals {
  vpc_id             = data.terraform_remote_state.cluster.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.cluster.outputs.private_subnet_ids
  db_client_sg_id    = data.terraform_remote_state.cluster.outputs.db_client_sg_id
  db_host            = data.terraform_remote_state.database.outputs.db_host
  db_port            = try(data.terraform_remote_state.database.outputs.db_port, 5432)
  db_name            = data.terraform_remote_state.database.outputs.db_name
  db_username        = coalesce(try(data.terraform_remote_state.database.outputs.db_username, null), var.db_username)
}

resource "aws_security_group" "vpc_link" {
  name                   = "${var.project}-api-vpc-link-sg"
  description            = "Egress security group for API Gateway VPC Link"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  egress {
    description = "Reach the internal NLB"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-auth-cpf"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.project}-auth"
  retention_in_days = 7
}

resource "aws_lambda_function" "auth" {
  function_name    = "${var.project}-auth-cpf"
  role             = data.aws_iam_role.lab.arn
  runtime          = "java21"
  handler          = var.lambda_handler
  filename         = var.lambda_artifact_path
  source_code_hash = filebase64sha256(var.lambda_artifact_path)
  memory_size      = 1024
  timeout          = 20
  publish          = true
  tracing_config { mode = "Active" }

  vpc_config {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [local.db_client_sg_id]
  }

  environment {
    variables = {
      DB_HOST     = local.db_host
      DB_PORT     = tostring(local.db_port)
      DB_NAME     = local.db_name
      DB_URL      = "jdbc:postgresql://${local.db_host}:${local.db_port}/${local.db_name}"
      DB_USER     = local.db_username
      DB_PASSWORD = var.db_password
      JWT_SECRET  = var.jwt_secret
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_alias" "prod" {
  name             = "prod"
  description      = "Production alias for the published CPF authentication Lambda version"
  function_name    = aws_lambda_function.auth.function_name
  function_version = aws_lambda_function.auth.version
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project}-edge"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project}-internal-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = local.private_subnet_ids
}

resource "aws_apigatewayv2_integration" "auth" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.prod.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "service" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = data.aws_lb_listener.internal_api.arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "auth" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/auth/cpf"
  target    = "integrations/${aws_apigatewayv2_integration.auth.id}"
}

resource "aws_apigatewayv2_route" "service" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.service.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "prod"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_throttling_burst_limit
    throttling_rate_limit  = var.api_throttling_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format          = jsonencode({ requestId = "$context.requestId", routeKey = "$context.routeKey", status = "$context.status", integrationStatus = "$context.integration.status" })
  }
}

resource "aws_lambda_permission" "gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth.function_name
  qualifier     = aws_lambda_alias.prod.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
