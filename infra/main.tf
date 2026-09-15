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
  # During teardown the RDS state can already be empty. These fallbacks keep the
  # serverless destroy plan evaluable; no placeholder is applied to state resources.
  db_host     = try(data.terraform_remote_state.database.outputs.db_host, "destroy.invalid")
  db_port     = try(data.terraform_remote_state.database.outputs.db_port, 5432)
  db_name     = try(data.terraform_remote_state.database.outputs.db_name, "workshop")
  db_username = coalesce(try(data.terraform_remote_state.database.outputs.db_username, null), var.db_username)
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

# A Lambda anexa este grupo junto com o db_client_sg do cluster. Aquele grupo
# existe para autorizar a origem no RDS e so libera saida na 5432, entao sozinho
# ele impede o agente ADOT de alcancar o endpoint OTLP da New Relic: o export
# falha por timeout, sem erro de credencial, e a telemetria se perde em silencio.
# Criar o grupo aqui mantem a fronteira entre os repositorios e nao altera a
# saida dos nodes do EKS, que compartilham o db_client_sg.
resource "aws_security_group" "lambda" {
  name                   = "${var.project}-auth-lambda-sg"
  description            = "Egress security group for the CPF authentication Lambda"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  egress {
    description = "Export OTLP telemetry to New Relic over HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Reach the RDS instance inside the VPC"
    from_port   = local.db_port
    to_port     = local.db_port
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.cluster.outputs.vpc_cidr]
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

  # O wrapper da layer ADOT reserva dez segundos para o flush final da
  # telemetria (OTEL_INSTRUMENTATION_AWS_LAMBDA_FLUSH_TIMEOUT). Com o limite em
  # vinte segundos a funcao respondia em cerca de um segundo e ficava os dez
  # restantes bloqueada no flush, que era abortado junto com a invocacao: as
  # duracoes ficavam cravadas em 10.010 ms e nada chegava a New Relic.
  timeout = 40
  publish = true
  layers  = [var.adot_layer_arn]
  tracing_config { mode = "Active" }

  vpc_config {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [local.db_client_sg_id, aws_security_group.lambda.id]
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

      # ADOT Java agent configuration. The AWSOpenTelemetryDistroJava layer ships
      # only the Java agent and the otel-instrument wrapper: it has no embedded
      # collector, so the SDK exports OTLP straight to New Relic. The API key is
      # held in a sensitive Terraform variable and is never exposed in an
      # output or log statement.
      AWS_LAMBDA_EXEC_WRAPPER  = "/opt/otel-instrument"
      OTEL_SERVICE_NAME        = "workshop-auth-serverless"
      OTEL_SERVICE_VERSION     = var.service_version
      OTEL_RESOURCE_ATTRIBUTES = "service.name=workshop-auth-serverless,service.version=${var.service_version},deployment.environment=${var.deployment_environment}"
      OTEL_TRACES_EXPORTER     = "otlp"
      OTEL_METRICS_EXPORTER    = "otlp"
      OTEL_LOGS_EXPORTER       = "otlp"
      # The SDK exports directly to New Relic over OTLP/HTTP protobuf, which New
      # Relic recommends and which avoids gRPC connection setup on cold start.
      # New Relic requires delta temporality for metrics.
      OTEL_EXPORTER_OTLP_ENDPOINT                       = var.new_relic_otlp_endpoint
      OTEL_EXPORTER_OTLP_PROTOCOL                       = "http/protobuf"
      OTEL_EXPORTER_OTLP_HEADERS                        = "api-key=${var.new_relic_api_key}"
      OTEL_EXPORTER_OTLP_COMPRESSION                    = "gzip"
      OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE = "delta"

      # Application Signals defaults to true and would ship a duplicate copy of
      # the telemetry to CloudWatch/X-Ray. W5 targets New Relic only.
      OTEL_AWS_APPLICATION_SIGNALS_ENABLED = "false"

      # A Lambda injeta _X_AMZN_TRACE_ID com Sampled=0 e o wrapper da camada
      # inclui o propagador xray, que aceita esse valor como um pai valido e
      # nao amostrado. O sampler padrao, parentbased_always_on, respeita o pai
      # e descarta o span raiz: os spans sao criados, nunca gravados e nunca
      # exportados, o que explica o agente exportar logs e metricas e nunca
      # traces. always_on ignora a decisao do pai e preserva a continuidade de
      # contexto com o API Gateway, que remover o propagador xray quebraria.
      OTEL_TRACES_SAMPLER = "always_on"

      # A instrumentacao do handler fica ligada porque e ela que faz o flush no
      # fim da invocacao. Desligada, o processo congela apos a resposta e o
      # BatchSpanProcessor nunca envia: o span aparece no log com trace.id, mas
      # nunca chega a New Relic. Ela nao duplica o span da fachada porque nao
      # reconhece APIGatewayV2HTTPEvent nesta versao da camada.
      OTEL_INSTRUMENTATION_AWS_LAMBDA_ENABLED = "true"

      # Exporta cada lote assim que fecha, em vez de aguardar o intervalo do
      # processador em lote, que a invacacao congelada nunca alcanca.
      OTEL_BSP_SCHEDULE_DELAY        = "200"
      OTEL_BSP_MAX_EXPORT_BATCH_SIZE = "1"

      OTEL_METRIC_EXPORT_INTERVAL = "5000"
      OTEL_EXPORTER_OTLP_TIMEOUT  = "8000"
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
  request_parameters = {
    "overwrite:path" = "$request.path"
  }
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
